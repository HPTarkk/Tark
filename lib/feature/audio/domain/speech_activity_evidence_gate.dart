/// Lightweight evidence gate between noisy per-frame voice activity and Smart
/// Music Ducking.
///
/// A single wind/engine spike must not duck shared music, while real speech
/// still needs a fast response. The gate therefore asks for a short sustained
/// active window before opening and a longer quiet window before closing. The
/// existing [MusicDuckingEnvelope] remains responsible for the audible
/// attack/release/hangover shape after this boolean decision.
class SpeechActivityEvidenceGate {
  SpeechActivityEvidenceGate({
    this.activeEvidenceMs = 60,
    this.inactiveEvidenceMs = 240,
  }) : assert(activeEvidenceMs >= 0),
       assert(inactiveEvidenceMs >= 0);

  final int activeEvidenceMs;
  final int inactiveEvidenceMs;

  bool _active = false;
  int _activeEvidence = 0;
  int _inactiveEvidence = 0;

  bool get isActive => _active;

  bool advance({required bool voiceEvidence, required int elapsedMs}) {
    if (elapsedMs <= 0) return _active;

    if (voiceEvidence) {
      _inactiveEvidence = 0;
      if (_active) return true;
      _activeEvidence += elapsedMs;
      if (_activeEvidence >= activeEvidenceMs) {
        _active = true;
        _activeEvidence = 0;
      }
      return _active;
    }

    _activeEvidence = 0;
    if (!_active) return false;
    _inactiveEvidence += elapsedMs;
    if (_inactiveEvidence >= inactiveEvidenceMs) {
      _active = false;
      _inactiveEvidence = 0;
    }
    return _active;
  }

  void reset() {
    _active = false;
    _activeEvidence = 0;
    _inactiveEvidence = 0;
  }
}
