import 'float64_fifo.dart';

/// Independent receive-side jitter buffer for Shared Music — the media
/// analog of `AudioPlaybackBuffer`, deliberately smaller. See #30.
///
/// Pull-based ([pullFrame]), unlike `AudioPlaybackBuffer`: it owns no timer
/// of its own. `AudioPlaybackBuffer`'s fixed-cadence drain timer is the one
/// proven-safe writer to the native output ring (see that class's own "do
/// not change the drain cadence" doc) — a second independent timer writing
/// to the same sink would not *mix* with voice's output, it would
/// concatenate two unrelated PCM streams into one ring buffer, which is
/// audibly wrong regardless of cadence. So the caller (`AudioEngineImpl`)
/// pulls a same-length frame from this buffer and numerically sums it onto
/// whatever voice is writing, at voice's own write points, plus its own
/// small coordinator tick for stretches where voice has nothing queued at
/// all — see that class's own doc for the mixing shape.
///
/// Deliberately simpler than `AudioPlaybackBuffer` in one specific way:
/// a sender whose sequence counter jumps far backward is resynced
/// immediately rather than going through that class's multi-packet
/// restart-vs-duplicate-route confirmation. That confirmation defends
/// against a WiFi peer being heard on two routes at once — already excluded
/// upstream of this buffer by the same route-pinning gate voice benefits
/// from (`_acceptRoute`, run once per packet before either stream sees it) —
/// so reproducing that machinery here would be defending against a case the
/// transport layer already prevents. Everything else (per-sender sequence
/// tracking, gap concealment, late/stale drop, bounded queue) is the same
/// shape as voice's, independently — no shared expected-sequence map or
/// buffer target, so one stream's loss/reorder can never affect the other's.
class MediaReceiveBuffer {
  MediaReceiveBuffer({
    int sampleRate = 48000,
    int targetBufferMs = kDefaultTargetBufferMs,
    int maxQueueMs = kDefaultMaxQueueMs,
  }) : _sampleRate = sampleRate,
       _targetSamples = sampleRate * targetBufferMs ~/ 1000,
       _maxQueueSamples = sampleRate * maxQueueMs ~/ 1000;

  /// Deliberately looser than `AudioPlaybackBuffer`'s 100 ms default — music
  /// is enjoyment-critical, not safety-critical, so a little extra cushion
  /// against jitter costs nothing conversation would notice. Still bounded —
  /// see [kDefaultMaxQueueMs].
  static const int kDefaultTargetBufferMs = 150;

  /// Bounded, same reasoning as `AudioPlaybackBuffer.kMaxQueueMs`: only a
  /// memory backstop, [_trimStep] (see [pullFrame]) keeps latency well below
  /// this in practice.
  static const int kDefaultMaxQueueMs = 1500;

  static const int _maxConcealedGapChunks = 50;
  static const int _maxReorderChunks = 50;

  final int _sampleRate;
  final int _targetSamples;
  final int _maxQueueSamples;
  late final int _trimStepSamples = _sampleRate * 10 ~/ 1000;

  final Float64Fifo _queue = Float64Fifo(4096);
  bool _filling = true;

  final Map<String, int> _expectedSeqBySender = {};
  final Map<String, int> _lastChunkLenBySender = {};

  int _underruns = 0;
  int _trims = 0;
  int _overflowDrops = 0;
  int _concealedSamples = 0;

  int get queuedSamples => _queue.length;
  int get targetSamples => _targetSamples;
  int get underruns => _underruns;
  int get trims => _trims;
  int get overflowDrops => _overflowDrops;
  int get concealedSamples => _concealedSamples;
  bool get isFilling => _filling;

  /// Feed one decoded media frame. Same contract as
  /// `AudioPlaybackBuffer.feed`: [seq] is [senderId]'s own monotonically
  /// increasing counter, scoped independently of voice's.
  void feed(List<double> samples, int seq, String senderId) {
    final expectedSeq = _expectedSeqBySender[senderId];
    final lastChunkLen = _lastChunkLenBySender[senderId] ?? samples.length;

    if (expectedSeq == null) {
      // First packet from this sender — nothing to compare against yet.
    } else if (seq < expectedSeq) {
      final behind = expectedSeq - seq;
      if (behind <= _maxReorderChunks) {
        return; // Ordinary reordering, too old to splice back in.
      }
      // Far behind: resynced immediately (unlike voice — see the class doc
      // for why that confirmation isn't reproduced here) by simply falling
      // through and adopting this sequence as the new baseline below.
    } else if (seq > expectedSeq) {
      final missing = seq - expectedSeq;
      if (missing <= _maxConcealedGapChunks) {
        final gap = missing * lastChunkLen;
        _concealedSamples += gap;
        _enqueueSilence(gap);
      }
      // A larger gap resyncs without filling silence — a jump is preferable
      // to seconds of manufactured silence for what music playback is for.
    }

    _expectedSeqBySender[senderId] = seq + 1;
    _lastChunkLenBySender[senderId] = samples.length;
    _enqueue(samples);
  }

  void _enqueue(List<double> samples) {
    _queue.addAll(samples);
    _dropOverflow();
  }

  void _enqueueSilence(int count) {
    _queue.addZeros(count);
    _dropOverflow();
  }

  /// Checked after adding, not before: a single incoming batch can — unlike
  /// voice's small, fixed-size mic chunks — occasionally be large relative
  /// to the cap (e.g. a big concealed gap), so the cap has to bound the
  /// queue's actual resulting size rather than only guard against many small
  /// additions accumulating past it.
  void _dropOverflow() {
    if (_queue.length <= _maxQueueSamples) return;
    _overflowDrops++;
    _queue.discardFirst(_queue.length - _maxQueueSamples);
  }

  /// Returns exactly [count] samples once the cushion has filled and enough
  /// is queued, trimming any backlog toward [targetSamples] first. Null
  /// while filling or genuinely starved — unlike `AudioPlaybackBuffer`,
  /// nothing requires this buffer to always emit something: the caller mixes
  /// whatever comes back onto voice's own frame, and null just means "no
  /// music contribution this tick," which is silence by omission rather
  /// than a decision to synthesize one.
  List<double>? pullFrame(int count) {
    if (_filling) {
      if (_queue.length < _targetSamples) return null;
      _filling = false;
    }

    final trimThreshold = _targetSamples * 2;
    if (_queue.length > trimThreshold) {
      final excess = _queue.length - _targetSamples;
      _queue.discardFirst(
        excess < _trimStepSamples ? excess : _trimStepSamples,
      );
      _trims++;
    }

    if (_queue.length < count) {
      _underruns++;
      _filling = true;
      return null;
    }
    return _queue.takeFirst(count);
  }

  /// Reset on a detected reconnect — clears queued audio and all per-sender
  /// sequence state, independent of `AudioPlaybackBuffer.reset()`.
  void reset() {
    _queue.clear();
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
  }

  /// No timer to cancel (see the class doc) — provided for symmetry with
  /// `AudioPlaybackBuffer.dispose()` and so a caller can treat both streams
  /// uniformly at teardown.
  void dispose() {
    _queue.clear();
  }
}
