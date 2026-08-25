import 'dart:math';

enum CaptureHealthState {
  starting,
  audible,
  silentIdle,
  blockedWhileMediaPlaying,
  stalled,
  stopped,
  unsupported,
}

class CaptureHealthEvidence {
  const CaptureHealthEvidence({
    required this.captureStarted,
    required this.elapsedMs,
    required this.msSinceLastFrame,
    required this.lastFrameRms,
    required this.externalMediaPlaying,
    required this.mediaPlayingKnown,
    required this.explicitlyStopped,
    required this.supported,
  });

  final bool captureStarted;
  final int elapsedMs;
  final int? msSinceLastFrame;
  final double? lastFrameRms;
  final bool externalMediaPlaying;
  final bool mediaPlayingKnown;
  final bool explicitlyStopped;
  final bool supported;
}

class CaptureHealthSnapshot {
  const CaptureHealthSnapshot({
    required this.state,
    required this.reasonCode,
    this.timeToFirstAudibleFrameMs,
  });

  final CaptureHealthState state;
  final String reasonCode;
  final int? timeToFirstAudibleFrameMs;

  bool get mayTransmitMedia => state == CaptureHealthState.audible;
  bool get needsUserAction =>
      state == CaptureHealthState.blockedWhileMediaPlaying ||
      state == CaptureHealthState.unsupported;
}

class CaptureHealthClassifier {
  const CaptureHealthClassifier({
    this.firstFrameGraceMs = 1500,
    this.stallAfterMs = 1200,
    this.audibleRmsFloor = 0.0005,
  });

  final int firstFrameGraceMs;
  final int stallAfterMs;
  final double audibleRmsFloor;

  CaptureHealthSnapshot classify(
    CaptureHealthEvidence evidence, {
    int? firstAudibleFrameAtMs,
  }) {
    if (!evidence.supported) {
      return const CaptureHealthSnapshot(
        state: CaptureHealthState.unsupported,
        reasonCode: 'capture_unsupported',
      );
    }
    if (evidence.explicitlyStopped) {
      return const CaptureHealthSnapshot(
        state: CaptureHealthState.stopped,
        reasonCode: 'capture_user_stopped',
      );
    }
    if (!evidence.captureStarted || evidence.elapsedMs < firstFrameGraceMs) {
      return const CaptureHealthSnapshot(
        state: CaptureHealthState.starting,
        reasonCode: 'capture_starting',
      );
    }

    final rms = evidence.lastFrameRms;
    final hasAudibleFrame = rms != null && rms >= audibleRmsFloor;
    if (hasAudibleFrame) {
      return CaptureHealthSnapshot(
        state: CaptureHealthState.audible,
        reasonCode: 'capture_audible',
        timeToFirstAudibleFrameMs: firstAudibleFrameAtMs,
      );
    }

    final silenceAge = evidence.msSinceLastFrame;
    if (silenceAge != null && silenceAge >= stallAfterMs) {
      return const CaptureHealthSnapshot(
        state: CaptureHealthState.stalled,
        reasonCode: 'capture_frame_stalled',
      );
    }

    if (evidence.mediaPlayingKnown && evidence.externalMediaPlaying) {
      return const CaptureHealthSnapshot(
        state: CaptureHealthState.blockedWhileMediaPlaying,
        reasonCode: 'capture_blocked_media_active',
      );
    }

    return const CaptureHealthSnapshot(
      state: CaptureHealthState.silentIdle,
      reasonCode: 'capture_silent_idle',
    );
  }
}

/// Stateful evidence collector used by the real playback-capture stream.
///
/// It deliberately owns no timer/platform API. Callers provide clock and media
/// session evidence, which keeps behavior deterministic and unit-testable.
class CaptureHealthMonitor {
  CaptureHealthMonitor({this.classifier = const CaptureHealthClassifier()});

  final CaptureHealthClassifier classifier;

  DateTime? _startedAt;
  DateTime? _lastFrameAt;
  double? _lastFrameRms;
  int? _firstAudibleFrameAtMs;
  bool _supported = true;
  bool _stopped = true;

  void start(DateTime now, {required bool supported}) {
    _startedAt = now;
    _lastFrameAt = null;
    _lastFrameRms = null;
    _firstAudibleFrameAtMs = null;
    _supported = supported;
    _stopped = false;
  }

  void stop() {
    _stopped = true;
  }

  CaptureHealthSnapshot observeFrame(
    List<double> samples,
    DateTime now, {
    required bool mediaPlayingKnown,
    required bool externalMediaPlaying,
  }) {
    _lastFrameAt = now;
    _lastFrameRms = _rms(samples);
    final startedAt = _startedAt;
    if (_firstAudibleFrameAtMs == null &&
        startedAt != null &&
        _lastFrameRms! >= classifier.audibleRmsFloor) {
      _firstAudibleFrameAtMs = max(0, now.difference(startedAt).inMilliseconds);
    }
    return snapshot(
      now,
      mediaPlayingKnown: mediaPlayingKnown,
      externalMediaPlaying: externalMediaPlaying,
    );
  }

  CaptureHealthSnapshot snapshot(
    DateTime now, {
    required bool mediaPlayingKnown,
    required bool externalMediaPlaying,
  }) {
    final startedAt = _startedAt;
    final elapsedMs = startedAt == null
        ? 0
        : max(0, now.difference(startedAt).inMilliseconds);
    final lastFrameAt = _lastFrameAt;
    final sinceFrame = lastFrameAt == null
        ? null
        : max(0, now.difference(lastFrameAt).inMilliseconds);

    return classifier.classify(
      CaptureHealthEvidence(
        captureStarted: startedAt != null && !_stopped,
        elapsedMs: elapsedMs,
        msSinceLastFrame: sinceFrame,
        lastFrameRms: _lastFrameRms,
        externalMediaPlaying: externalMediaPlaying,
        mediaPlayingKnown: mediaPlayingKnown,
        explicitlyStopped: _stopped,
        supported: _supported,
      ),
      firstAudibleFrameAtMs: _firstAudibleFrameAtMs,
    );
  }

  void reset() {
    _startedAt = null;
    _lastFrameAt = null;
    _lastFrameRms = null;
    _firstAudibleFrameAtMs = null;
    _supported = true;
    _stopped = true;
  }

  static double _rms(List<double> samples) {
    if (samples.isEmpty) return 0;
    var sumSquares = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    return sqrt(sumSquares / samples.length);
  }
}
