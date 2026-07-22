import 'dart:async';

import '../../../core/utils/logger.dart';
import '../domain/float64_fifo.dart';

/// Jitter buffer that smooths bursty UDP/Bluetooth audio delivery before
/// playback.
///
/// Packets arrive in uneven bursts, can be lost, and can arrive out of order.
/// Writing them directly to the audio output causes glitches (underruns
/// between bursts, overruns on arrival, and — without sequence tracking —
/// jumbled/discontinuous speech when packets are lost or reordered). This
/// buffer accumulates samples until [targetBufferMs] worth have arrived, then
/// drains them at a steady [drainIntervalMs] rate via a periodic timer. Lost
/// packets (detected via sequence number gaps) are concealed with silence
/// rather than silently skipped, which keeps audio timing intact instead of
/// producing a "fast forward" jumble.
///
/// Sequence tracking is kept per sender: a WiFi channel can have more than
/// one other participant, and each sender has its own independent sequence
/// counter. Tracking a single shared "expected sequence" across senders
/// meant that once any one sender's stream advanced it, every other
/// sender's (lower-numbered) packets would permanently fail the stale-packet
/// check below and get silently dropped for the rest of the session.
///
/// ## Do not change the drain cadence
///
/// The drain pushes a **fixed [_drainSize] samples per tick**. This looks like
/// something worth "improving" — a periodic timer on the UI isolate is
/// imprecise, so draining a fixed slice per tick doesn't track real time
/// exactly. Replacing it with an elapsed-wall-clock drain (variable samples
/// per tick, matching real time) was tried and produced badly chopped audio on
/// Bluetooth, repeatedly, across several tunings of depth and thresholds. The
/// fixed cadence is the only cadence this pipeline is known to play cleanly.
///
/// Latency is therefore bounded WITHOUT touching the cadence: stale audio is
/// trimmed from the head of the queue (see [_trimStep]). That changes what
/// is pushed, never how fast, so it cannot starve or overrun the downstream
/// native ring.
///
/// ## Where playback latency actually lives
///
/// End-to-end delay is this queue plus the native output ring downstream
/// (`audio_io_miniaudio.cpp`, 8192 samples). That ring is drained by the audio
/// hardware at exactly real time and **silently discards** whatever doesn't
/// fit on write, so it cannot itself hold seconds of audio — which is why a
/// multi-second delay could only ever have come from this queue.
class AudioPlaybackBuffer {
  AudioPlaybackBuffer({
    required Sink<List<double>> output,
    int sampleRate = 48000,
    int targetBufferMs = 100,
    int drainIntervalMs = 10,
    this.debugLogging = false,
  }) : _output = output,
       _sampleRate = sampleRate,
       _targetSamples = sampleRate * targetBufferMs ~/ 1000,
       _drainSize = sampleRate * drainIntervalMs ~/ 1000,
       _drainIntervalMs = drainIntervalMs,
       _defaultChunkLen = sampleRate * 10 ~/ 1000;

  final Sink<List<double>> _output;
  final int _sampleRate;
  final int _targetSamples;
  final int _drainSize;
  final int _drainIntervalMs;
  final int _defaultChunkLen;

  /// Periodically logs queue depth and event counters. Left in deliberately:
  /// this bug was chased through several wrong theories for want of a single
  /// real measurement from a device.
  final bool debugLogging;

  // Unboxed ring buffer: a Queue<double> here boxed every received sample
  // and unboxed it again on drain — tens of thousands of heap allocations
  // per second of playback, enough GC pressure to pause the UI isolate.
  final Float64Fifo _queue = Float64Fifo(8192);
  Timer? _drainTimer;
  bool _filling = true;

  /// Hard cap, scaled to this instance's actual sample rate (previously a
  /// hardcoded 48 kHz sample count — at a 16 kHz output rate, as commonly
  /// negotiated over Bluetooth SCO/HFP, that made the real cap 3x longer in
  /// time than intended). This is only a memory backstop; [_trimStep]
  /// bounds latency well before this.
  static const int kMaxQueueMs = 1000;
  late final int _maxQueueSamples = _sampleRate * kMaxQueueMs ~/ 1000;

  /// Depth above which the queue is considered to be holding stale audio.
  /// Must be above target: Bluetooth delivery is bursty and the queue
  /// routinely spikes for a moment.
  late final int _trimThreshold = _targetSamples * 2;

  /// Latency is walked down in small steps rather than snapped back in one
  /// splice. A single trim big enough to cover the whole backlog removes an
  /// audible chunk of speech — a whole syllable. Dropping [_trimStepSamples]
  /// (10 ms, softened by the fade ramp) every [_trimIntervalTicks] is
  /// perceptually close to invisible and reaches the same place within a few
  /// seconds.
  late final int _trimStepSamples = _sampleRate * 10 ~/ 1000;
  late final int _trimIntervalTicks = (200 / _drainIntervalMs).ceil();
  int _sinceTrimTicks = 0;

  /// Beyond this many missing chunks in a row, treat it as a new talk burst
  /// (e.g. after a VOX silence) instead of filling a huge silence gap.
  static const int _maxConcealedGapChunks = 50;

  /// Short ramp applied right after playback resumes (initial fill, after an
  /// underrun, or after a trim) to avoid an audible click at the
  /// silence→audio or splice boundary.
  late final int _fadeInSamples = (_sampleRate * 0.003).round().clamp(
    1,
    1 << 30,
  );
  int _fadeRemaining = 0;

  // Sequence tracking for loss/reorder detection, per sender id.
  final Map<String, int> _expectedSeqBySender = {};
  final Map<String, int> _lastChunkLenBySender = {};

  // Diagnostics. The per-window sample counters are the important ones: they
  // measure directly whether the feed outruns the fixed-cadence drain, and by
  // how much, which is the thing every theory about this bug has hinged on.
  int _underruns = 0;
  int _trims = 0;
  int _overflowDrops = 0;
  int _fedWindow = 0;
  int _concealedWindow = 0;
  int _drainedWindow = 0;
  int _logTicks = 0;
  late final int _logEveryTicks = (2000 / _drainIntervalMs).ceil();

  int _ms(int samples) => samples * 1000 ~/ _sampleRate;
  int get _queueMs => _ms(_queue.length);

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
      _overflowDrops++;
      _queue.discardFirst(overflow < _queue.length ? overflow : _queue.length);
    }
  }

  void _enqueue(List<double> samples) {
    _dropOverflow(samples.length);
    _queue.addAll(samples);
    _fedWindow += samples.length;
  }

  void _enqueueSilence(int count) {
    _dropOverflow(count);
    _queue.addZeros(count);
    _concealedWindow += count;
  }

  /// Drop one small step off the stale head, walking playback latency down
  /// toward target.
  ///
  /// This is the only thing that lowers latency here, and it is purely a
  /// content operation — the drain keeps pushing its fixed slice per tick
  /// either way.
  void _trimStep() {
    final excess = _queue.length - _targetSamples;
    if (excess <= 0) return;
    _queue.discardFirst(excess < _trimStepSamples ? excess : _trimStepSamples);
    _fadeRemaining = _fadeInSamples;
    _trims++;
  }

  void _startDraining() {
    _drainTimer?.cancel();
    _fadeRemaining = _fadeInSamples;
    _sinceTrimTicks = 0;
    _drainTimer = Timer.periodic(Duration(milliseconds: _drainIntervalMs), (_) {
      if (debugLogging && ++_logTicks >= _logEveryTicks) {
        _logTicks = 0;
        Logger.log(
          'jitter buffer: ${_queueMs}ms queued (target ${_ms(_targetSamples)}ms)'
          ' | 2s window: fed ${_ms(_fedWindow)}ms'
          ' + concealed ${_ms(_concealedWindow)}ms'
          ' vs drained ${_ms(_drainedWindow)}ms'
          ' | underruns=$_underruns trims=$_trims drops=$_overflowDrops',
        );
        _fedWindow = 0;
        _concealedWindow = 0;
        _drainedWindow = 0;
      }

      if (_queue.length < _drainSize) {
        // Underrun — stop and wait for the buffer to refill.
        _underruns++;
        _filling = true;
        _drainTimer?.cancel();
        _drainTimer = null;
        return;
      }

      // Backlog above target: walk it down one small step at a time. The feed
      // outruns this fixed-cadence drain — that is how the session used to
      // accumulate a multi-second delay — so the difference has to be given
      // back somewhere, and small steps are far less audible than one splice.
      if (_queue.length > _trimThreshold) {
        if (++_sinceTrimTicks >= _trimIntervalTicks) {
          _sinceTrimTicks = 0;
          _trimStep();
        }
      } else {
        _sinceTrimTicks = 0;
      }

      final chunk = _queue.takeFirst(_drainSize);
      _drainedWindow += _drainSize;
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
    _queue.clear();
    _filling = true;
    _expectedSeqBySender.clear();
    _lastChunkLenBySender.clear();
    _fadeRemaining = 0;
    _sinceTrimTicks = 0;
  }

  /// Cancel the drain timer. Call before discarding this object.
  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }
}
