enum CaptureHealthState {
  starting,
  audible,
  silentIdle,
  blockedWhileMediaPlaying,
  stalled,
  stopped,
  unsupported,
}

/// Evidence used to classify Android AudioPlaybackCapture without pretending
/// that a running MediaProjection service means useful audio is flowing.
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

  /// True only when another media session is positively confirmed as playing.
  final bool externalMediaPlaying;

  /// Whether notification/media-session access lets us draw any conclusion.
  /// False means unknown, never "nothing is playing".
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

/// Pure classifier used by the capture owner. Thresholds are intentionally
/// conservative starting values and deterministic so Samsung/Xiaomi field
/// evidence can tune them without changing the ownership model.
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

    // No media-session evidence is intentionally not treated as a block. A
    // user may simply have nothing playing, and without notification access we
    // are not allowed to infer otherwise.
    return const CaptureHealthSnapshot(
      state: CaptureHealthState.silentIdle,
      reasonCode: 'capture_silent_idle',
    );
  }
}
