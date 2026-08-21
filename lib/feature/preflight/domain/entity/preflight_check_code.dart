/// Stable machine ids for [RecoveryCheck.code], scoped to Preflight (#33).
///
/// Grown one checkpoint at a time — only codes an already-landed check
/// actually emits belong here. These are what Preflight's diagnostics
/// requirement logs (check code + pass/warn/fail + duration), so once
/// shipped a code should not be renamed or reused for a different meaning.
abstract final class PreflightCheckCode {
  // Check 1 — microphone.
  static const micOk = 'mic_ok';
  static const micPermissionDenied = 'mic_permission_denied';
  static const micNoFrames = 'mic_no_frames';

  // Check 2 — playback/output route.
  static const routeBluetooth = 'route_bluetooth';
  static const routeWired = 'route_wired';
  static const routePhoneSpeaker = 'route_phone_speaker';
  static const routeUnknown = 'route_unknown';

  // Check 4 — network/transport readiness.
  static const transportBlocked = 'transport_blocked';
  static const transportNotAttempted = 'transport_not_attempted';
  static const transportReady = 'transport_ready';
  static const transportDegraded = 'transport_degraded';
  static const transportDown = 'transport_down';

  // Check 5 — peer reachability/bidirectional audibility.
  static const peerNotPresent = 'peer_not_present';
  static const peerUnconfirmed = 'peer_unconfirmed';
  static const peerConfirmed = 'peer_confirmed';

  // Check 6 — background execution readiness.
  static const backgroundOk = 'background_ok';
  static const backgroundNotificationDenied = 'background_notification_denied';
  static const backgroundBatteryRestricted = 'background_battery_restricted';

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
