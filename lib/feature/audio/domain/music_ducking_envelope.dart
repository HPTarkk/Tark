import 'dart:math';

import 'speech_activity_evidence_gate.dart';

/// Deterministic, centralized gain envelope for Smart Music Ducking.
///
/// Raw voice-active observations first pass through a lightweight evidence
/// gate. This keeps short wind/engine/noise spikes from moving music gain while
/// still allowing sustained/overlapping speech to duck within a bounded
/// response budget. The existing hangover then protects word gaps, and the
/// attack/release envelope remains click-free and multiplicative on top of the
/// user's own music volume.
class MusicDuckingEnvelope {
  MusicDuckingEnvelope({
    this.duckTarget = 0.3,
    this.attackMs = 120,
    this.releaseMs = 800,
    this.hangoverMs = 400,
    this.activeEvidenceMs = 60,
    this.inactiveEvidenceMs = 240,
  }) : assert(duckTarget >= 0.0 && duckTarget <= 1.0),
       assert(attackMs > 0),
       assert(releaseMs > 0),
       assert(hangoverMs >= 0),
       assert(activeEvidenceMs >= 0),
       assert(inactiveEvidenceMs >= 0),
       _evidenceGate = SpeechActivityEvidenceGate(
         activeEvidenceMs: activeEvidenceMs,
         inactiveEvidenceMs: inactiveEvidenceMs,
       );

  final double duckTarget;
  final int attackMs;
  final int releaseMs;
  final int hangoverMs;

  /// Sustained positive evidence required before raw VOX/talker activity is
  /// allowed to start ducking. The 60 ms default is deliberately below the
  /// 120 ms attack, so real speech is protected quickly without reacting to a
  /// single short noise frame.
  final int activeEvidenceMs;

  /// Sustained inactive evidence required before the speech gate closes.
  /// Combined with [hangoverMs], this prevents chatter across word gaps and
  /// noisy threshold crossings.
  final int inactiveEvidenceMs;

  final SpeechActivityEvidenceGate _evidenceGate;
  double _gain = 1.0;
  int _hangoverRemainingMs = 0;

  double get gain => _gain;
  bool get isDucked => _gain < 1.0;

  /// Exposed for diagnostics/tests; this is the qualified speech signal, not a
  /// raw per-frame VOX observation.
  bool get qualifiedVoiceActive => _evidenceGate.isActive;

  /// Advances the envelope by one media frame.
  ///
  /// [voiceActive] is treated as evidence only. The gain target changes only
  /// after that evidence survives [activeEvidenceMs]/[inactiveEvidenceMs].
  double advance({required bool voiceActive, required int frameDurationMs}) {
    final qualified = _evidenceGate.advance(
      voiceEvidence: voiceActive,
      elapsedMs: frameDurationMs,
    );

    if (qualified) {
      _hangoverRemainingMs = hangoverMs;
    } else if (_hangoverRemainingMs > 0) {
      _hangoverRemainingMs = max(0, _hangoverRemainingMs - frameDurationMs);
    }

    final target = (qualified || _hangoverRemainingMs > 0) ? duckTarget : 1.0;

    if (_gain == target) return _gain;

    final rampMs = target < _gain ? attackMs : releaseMs;
    final step = frameDurationMs / rampMs;
    _gain = target < _gain
        ? max(target, _gain - step)
        : min(target, _gain + step);
    return _gain;
  }

  /// Returns to full volume immediately and clears both the evidence gate and
  /// hangover so reconnect/media-stop cannot carry stale speech state forward.
  void reset() {
    _evidenceGate.reset();
    _gain = 1.0;
    _hangoverRemainingMs = 0;
  }
}
