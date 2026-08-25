/// Lightweight evidence gate between noisy per-frame voice activity and Smart
/// Music Ducking.
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
