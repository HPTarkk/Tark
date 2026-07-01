import 'dart:async';
import 'dart:collection';

/// Jitter buffer that smooths bursty UDP audio delivery before playback.
///
/// UDP packets arrive in uneven bursts, can be lost, and can arrive out of
/// order. Writing them directly to the audio output causes glitches
/// (underruns between bursts, overruns on arrival, and — without sequence
/// tracking — jumbled/discontinuous speech when packets are lost or
/// reordered). This buffer accumulates samples until [targetBufferMs] worth
/// have arrived, then drains them at a steady [drainIntervalMs] rate via a
/// periodic timer. Lost packets (detected via sequence number gaps) are
/// concealed with silence rather than silently skipped, which keeps audio
/// timing intact instead of producing a "fast forward" jumble.
///
/// Sequence tracking is kept per sender: a WiFi channel can have more than
/// one other participant, and each sender has its own independent sequence
/// counter. Tracking a single shared "expected sequence" across senders
/// meant that once any one sender's stream advanced it, every other
/// sender's (lower-numbered) packets would permanently fail the stale-packet
/// check below and get silently dropped for the rest of the session.
///
/// If the queue grows beyond [_maxQueueSamples] (2 s), oldest samples are
/// dropped to prevent unbounded memory growth and excessive latency.
class AudioPlaybackBuffer {
  AudioPlaybackBuffer({
    required Sink<List<double>> output,
    int sampleRate = 48000,
    int targetBufferMs = 60,
    int drainIntervalMs = 10,
  })  : _output = output,
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

  final Queue<double> _queue = Queue<double>();
  Timer? _drainTimer;
  bool _filling = true;

  /// Hard cap: 2 seconds of audio at 48 kHz.
  static const int _maxQueueSamples = 96000;

  /// Beyond this many missing chunks in a row, treat it as a new talk burst
  /// (e.g. after a VOX silence) instead of filling a huge silence gap.
  static const int _maxConcealedGapChunks = 50;

  /// Short ramp applied right after playback resumes (initial fill or after
  /// an underrun) to avoid an audible click at the silence→audio boundary.
  late final int _fadeInSamples = (_sampleRate * 0.003).round().clamp(1, 1 << 30);
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
        for (int i = 0; i < missing; i++) {
          _enqueue(List<double>.filled(lastChunkLen, 0.0));
        }
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

  void _enqueue(List<double> samples) {
    final overflow = (_queue.length + samples.length) - _maxQueueSamples;
    if (overflow > 0) {
      for (int i = 0; i < overflow && _queue.isNotEmpty; i++) {
        _queue.removeFirst();
      }
    }
    for (final s in samples) {
      _queue.addLast(s);
    }
  }

  void _startDraining() {
    _drainTimer?.cancel();
    _fadeRemaining = _fadeInSamples;
    _drainTimer = Timer.periodic(
      Duration(milliseconds: _drainIntervalMs),
      (_) {
        if (_queue.length < _drainSize) {
          // Underrun — stop and wait for the buffer to refill.
          _filling = true;
          _drainTimer?.cancel();
          _drainTimer = null;
          return;
        }
        final chunk = List<double>.generate(
          _drainSize,
          (_) => _queue.removeFirst(),
        );
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
      },
    );
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
  }

  /// Cancel the drain timer. Call before discarding this object.
  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }
}
