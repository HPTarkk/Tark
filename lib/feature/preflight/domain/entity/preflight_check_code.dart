/// Stable machine ids for [RecoveryCheck.code], scoped to Preflight (#33).
///
/// Grown one checkpoint at a time — only codes an already-landed check
/// actually emits belong here. These are what Preflight's diagnostics
/// requirement logs (check code + pass/warn/fail + duration), so once
/// shipped a code should not be renamed or reused for a different meaning.
abstract final class PreflightCheckCode {
  // Check 3 — audio profile/capability readiness.
  static const hdVoiceReady = 'hd_voice_ready';
  static const hdVoiceNegotiatedHd = 'hd_voice_negotiated_hd';
  static const hdVoiceStandard = 'hd_voice_standard';

  // Check 7 — Shared Music capability.
  static const sharedMusicAvailable = 'shared_music_available';
  static const sharedMusicUnavailable = 'shared_music_unavailable';

  // Check 8 — diagnostics readiness.
  static const diagnosticsOk = 'diagnostics_ok';
  static const diagnosticsMemoryOnly = 'diagnostics_memory_only';
  static const diagnosticsDisabled = 'diagnostics_disabled';
}
