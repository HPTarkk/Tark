import 'dart:async';
import 'dart:collection';

import '../../../core/observability/voice_metrics.dart';

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

  /// Hard cap, scaled to this instance's actual sample rate (previously a
  /// hardcoded 48 kHz sample count — at a 16 kHz output rate, as commonly
  /// negotiated over Bluetooth SCO/HFP, that made the real cap 6 s instead
  /// of 2 s, which is exactly how a session's playback delay could climb to
  /// ~6 s over time instead of being capped at 2 s).
  static const int kMaxQueueMs = 2000;
  late final int _maxQueueSamples = _sampleRate * kMaxQueueMs ~/ 1000;

  /// Ticks (at [_drainIntervalMs] each) the queue must stay sustained above
  /// target before drift-correction kicks in.
  late final int _catchUpTicks = (3000 / _drainIntervalMs).ceil();
  int _overTargetTicks = 0;
  bool _catchingUp = false;

  /// Beyond this many missing chunks in a row, treat it as a new talk burst
  /// (e.g. after a VOX silence) instead of filling a huge silence gap.
  static const int _maxConcealedGapChunks = 50;

  /// Short ramp applied right after playback resumes (initial fill or after
  /// an underrun) to avoid an audible click at the silence→audio boundary.
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
      VoiceMetrics.increment('audio_overrun_count');
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
    _overTargetTicks = 0;
    _catchingUp = false;
    _drainTimer = Timer.periodic(Duration(milliseconds: _drainIntervalMs), (_) {
      if (_queue.length < _drainSize) {
        // Underrun — stop and wait for the buffer to refill.
        VoiceMetrics.increment('audio_underrun_count');
        _filling = true;
        _drainTimer?.cancel();
        _drainTimer = null;
        return;
      }

      // Drift correction: independent sender/receiver clocks mean the
      // queue can creep above target even with zero packet loss. Left
      // unchecked, only the hard cap above would ever pull it back down —
      // which bounds memory but still lets real playback delay grow for
      // the whole session. Once sustained meaningfully above target for a
      // few seconds, briefly drain faster than real-time to walk it back.
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

      final drainSize = _catchingUp
          ? (_drainSize + _drainSize ~/ 6).clamp(1, _queue.length)
          : _drainSize;
      final chunk = List<double>.generate(
        drainSize,
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
    _overTargetTicks = 0;
    _catchingUp = false;
  }

  /// Cancel the drain timer. Call before discarding this object.
  void dispose() {
    _drainTimer?.cancel();
    _drainTimer = null;
  }
}
