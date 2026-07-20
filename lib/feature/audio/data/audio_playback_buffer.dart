import 'dart:async';

import '../domain/float64_fifo.dart';

/// Jitter buffer that smooths bursty UDP audio delivery before playback.
///
/// UDP packets arrive in uneven bursts, can be lost, and can arrive out of
/// order. Writing them directly to the audio output causes glitches
/// (underruns between bursts, overruns on arrival, and — without sequence
/// tracking — jumbled/discontinuous speech when packets are lost or
/// reordered). This buffer accumulates samples until [targetBufferMs] worth
/// have arrived, then drains them at real-time rate via a periodic timer.
/// Lost packets (detected via sequence number gaps) are concealed with
/// silence rather than silently skipped, which keeps audio timing intact
/// instead of producing a "fast forward" jumble.
///
/// Sequence tracking is kept per sender: a WiFi channel can have more than
/// one other participant, and each sender has its own independent sequence
/// counter. Tracking a single shared "expected sequence" across senders
/// meant that once any one sender's stream advanced it, every other
/// sender's (lower-numbered) packets would permanently fail the stale-packet
/// check below and get silently dropped for the rest of the session.
///
/// If independent sender/receiver clocks let the queue creep above target,
/// the drain loop walks it back — smoothly via drift correction, or in one
/// step (resync to target) once it runs past [_resyncThreshold] — so playback
/// latency stays near [targetBufferMs] instead of riding at a ceiling for the
/// whole session. [_maxQueueSamples] is a final memory backstop.
class AudioPlaybackBuffer {
  // 100 ms target: 60 ms proved too shallow on real WiFi between phones —
  // every scheduling burst or lost packet drained it dry, and each underrun
  // costs a full refill pause (audible chop). 100 ms of latency is
  // imperceptible in a walkie-talkie exchange; the smoothness is not.
  AudioPlaybackBuffer({
    required Sink<List<double>> output,
    int sampleRate = 48000,
    int targetBufferMs = 100,
    int drainIntervalMs = 10,
  }) : _output = output,
       _sampleRate = sampleRate,
       _targetSamples = sampleRate * targetBufferMs ~/ 1000,
       _drainIntervalMs = drainIntervalMs,
       _defaultChunkLen = sampleRate * 10 ~/ 1000;

  final Sink<List<double>> _output;
  final int _sampleRate;
  final int _targetSamples;
  final int _drainIntervalMs;
  final int _defaultChunkLen;

  // Unboxed ring buffer: a Queue<double> here boxed every received sample
  // and unboxed it again on drain — tens of thousands of heap allocations
  // per second of playback, enough GC pressure to pause the UI isolate.
  final Float64Fifo _queue = Float64Fifo(8192);
  Timer? _drainTimer;
  bool _filling = true;

  // Wall-clock drain accounting. Each tick removes however much audio real
  // time actually elapsed since the previous tick — not a fixed slice per
  // tick — so an imprecise or late UI-isolate timer can't fall behind and let
  // latency creep upward for the whole session. A monotonic Stopwatch avoids
  // system-clock jumps; the fractional-sample remainder is carried across
  // ticks so integer truncation can't slowly bias the drain rate.
  final Stopwatch _drainClock = Stopwatch();
  int _lastDrainMicros = 0;
  double _drainCarry = 0.0;

  /// A single late drain tick (e.g. right after the app was backgrounded)
  /// never tries to drain more than this much wall-clock time in one go; the
  /// resync below handles the leftover backlog.
  static const int _maxCatchUpMicros = 200 * 1000;

  /// Hard memory/latency backstop, scaled to this instance's actual sample
  /// rate. Kept just above [_resyncThreshold] so the drain-loop resync — which
  /// snaps latency back to target — normally governs and this only bounds
  /// memory in the worst case. Scaling by sample rate matters: a hardcoded
  /// 48 kHz sample count became a 3x-larger *time* cap at the 16 kHz rate
  /// commonly negotiated over Bluetooth SCO/HFP, which is how a session's
  /// playback delay used to climb to multiple seconds.
  static const int kMaxQueueMs = 250;
  late final int _maxQueueSamples = _sampleRate * kMaxQueueMs ~/ 1000;

  /// When the queue runs past this, the drain loop drops the oldest backlog in
  /// one step and snaps latency back to [_targetSamples], rather than playing
  /// out stale audio and riding at the ceiling for the rest of the session.
  late final int _resyncThreshold = _targetSamples * 2;

  /// Ticks (at [_drainIntervalMs] each) the queue must stay sustained above
  /// target before drift-correction kicks in.
  late final int _catchUpTicks = (3000 / _drainIntervalMs).ceil();
  int _overTargetTicks = 0;
  bool _catchingUp = false;

  /// Beyond this many missing chunks in a row, treat it as a new talk burst
  /// (e.g. after a VOX silence) instead of filling a huge silence gap.
  static const int _maxConcealedGapChunks = 50;

  /// Short ramp applied right after playback resumes (initial fill, after an
  /// underrun, or after a resync) to avoid an audible click at the
  /// silence→audio or splice boundary.
  late final int _fadeInSamples = (_sampleRate * 0.003).round().clamp(
    1,
    1 << 30,
  );
  int _fadeRemaining = 0;

  // Sequence tracking for loss/reorder detection, per sender id.
  final Map<String, int> _expectedSeqBySender = {};
  final Map<String, int> _lastChunkLenBySender = {};

  /// Feed incoming samples into the buffer.
  ///
  /// [seq] is the sender's monotonically increasing packet counter, scoped
  /// to [senderId]. Gaps are concealed with silence so playback timing stays
  /// correct; packets that arrive late (seq below what's already been
  /// consumed for that sender) are dropped instead of being spliced in out
  /// of order.
  void feed(List<double> samples, int seq, String senderId) {
    final expectedSeq = _expectedSeqBySender[senderId];
    final lastChunkLen = _lastChunkLenBySender[senderId] ?? _defaultChunkLen;

    if (expectedSeq == null) {
      // First packet from this sender — nothing to compare against yet.
    } else if (seq < expectedSeq) {
      // Stale/out-of-order packet — too late to play in sequence.
      return;
    } else if (seq > expectedSeq) {
      final missing = seq - expectedSeq;
      if (missing <= _maxConcealedGapChunks) {
        _enqueueSilence(missing * lastChunkLen);
      }
      // else: large gap (new talk burst) — resync without filling silence.
    }

    _expectedSeqBySender[senderId] = seq + 1;
    _lastChunkLenBySender[senderId] = samples.length;
    _enqueue(samples);

    if (_filling && _queue.length >= _targetSamples) {
      _filling = false;
      _startDraining();
    }
  }

  void _dropOverflow(int incoming) {
    final overflow = (_queue.length + incoming) - _maxQueueSamples;
    if (overflow > 0) {
      _queue.discardFirst(overflow < _queue.length ? overflow : _queue.length);
    }
  }

  void _enqueue(List<double> samples) {
    _dropOverflow(samples.length);
    _queue.addAll(samples);
  }

  void _enqueueSilence(int count) {
    _dropOverflow(count);
    _queue.addZeros(count);
  }

  void _startDraining() {
    _drainTimer?.cancel();
    _fadeRemaining = _fadeInSamples;
    _overTargetTicks = 0;
    _catchingUp = false;
    _drainCarry = 0.0;
    _drainClock
      ..reset()
      ..start();
    _lastDrainMicros = 0;
    _drainTimer = Timer.periodic(Duration(milliseconds: _drainIntervalMs), (_) {
      final nowMicros = _drainClock.elapsedMicroseconds;
      var elapsedMicros = nowMicros - _lastDrainMicros;
      _lastDrainMicros = nowMicros;

      // Hard resync first. If the backlog has run past the resync threshold
      // (a sudden burst, or the smooth drift correction below couldn't keep
      // up), drop the oldest audio down to target in one step so mouth-to-ear
      // latency snaps back instead of playing out stale audio for the rest of
      // the session. The drain debt just measured is stale time, so discard it
      // and let playback resume from target on the next tick (fade hides the
      // splice click).
      if (_queue.length > _resyncThreshold) {
        _queue.discardFirst(_queue.length - _targetSamples);
        _fadeRemaining = _fadeInSamples;
        _overTargetTicks = 0;
        _catchingUp = false;
        _drainCarry = 0.0;
        return;
      }

      if (elapsedMicros > _maxCatchUpMicros) elapsedMicros = _maxCatchUpMicros;
      _drainCarry += _sampleRate * elapsedMicros / 1000000.0;
      final baseDrain = _drainCarry.floor();
      if (baseDrain <= 0) return; // sub-sample tick — keep accumulating.

      if (_queue.length < baseDrain) {
        // Underrun — not enough buffered to keep up with real time. Stop and
        // wait for the buffer to refill back to target.
        _filling = true;
        _drainTimer?.cancel();
        _drainTimer = null;
        return;
      }
      _drainCarry -= baseDrain;

      // Drift correction: independent sender/receiver clocks mean the queue
      // can slowly creep above target even with zero packet loss. Once it has
      // stayed above target for a few seconds, drain a little faster than real
      // time to walk it back smoothly (no click) before it reaches the resync
      // threshold above.
      if (_queue.length > _targetSamples * 8 ~/ 5) {
        _overTargetTicks++;
        if (_overTargetTicks > _catchUpTicks) _catchingUp = true;
      } else {
        _overTargetTicks = 0;
        _catchingUp = false;
      }
      if (_catchingUp && _queue.length <= _targetSamples * 6 ~/ 5) {
        _catchingUp = false;
        _overTargetTicks = 0;
      }

      var drainSize = baseDrain;
      if (_catchingUp) {
        drainSize += baseDrain ~/ 6;
        if (drainSize > _queue.length) drainSize = _queue.length;
      }

      final chunk = _queue.takeFirst(drainSize);
      if (_fadeRemaining > 0) {
        final rampLen = _fadeRemaining < chunk.length
            ? _fadeRemaining
            : chunk.length;
        for (int i = 0; i < rampLen; i++) {
          final progress =
              (_fadeInSamples - _fadeRemaining + i + 1) / _fadeInSamples;
          chunk[i] *= progress.clamp(0.0, 1.0);
        }
        _fadeRemaining -= rampLen;
      }
      _output.add(chunk);
    });
  }

  /// Reset the buffer state (e.g. on network reconnect).
  void reset() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _drainClock
      ..stop()
      ..reset();
    _lastDrainMicros = 0;
    _drainCarry = 0.0;
    _queue.clear();
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
    _fadeRemaining = 0;
    _overTargetTicks = 0;
    _catchingUp = false;
  }

  /// Cancel the drain timer. Call before discarding this object.
  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
    _drainClock.stop();
  }
}
