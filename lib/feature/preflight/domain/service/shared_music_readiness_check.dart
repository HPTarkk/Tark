import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../entity/preflight_check_code.dart';

/// Check 7 — Shared Music capability (optional; must never fail voice
/// Preflight, so the unsupported branch is [RecoveryStatus.unknown] rather
/// than [RecoveryStatus.warn] or [RecoveryStatus.bad]).
///
/// [isSupported] is the caller's already-awaited
/// `SystemAudioCapture.isSupported` — this function stays synchronous/pure
/// so it's testable without a platform channel. Never call
/// `SystemAudioCapture.start()` to answer this check: that raises the
/// MediaProjection consent dialog, which the issue reserves for when the
/// user actually starts Shared Music.
RecoveryCheck sharedMusicReadinessCheck({
  required AppLocalizations s,
  required bool isSupported,
}) {
  if (isSupported) {
    return RecoveryCheck(
      label: s.preflight_check_shared_music,
      detail: s.preflight_shared_music_available,
      status: RecoveryStatus.ok,
      code: PreflightCheckCode.sharedMusicAvailable,
    );
  }
  return RecoveryCheck(
    label: s.preflight_check_shared_music,
    detail: s.preflight_shared_music_unavailable,
    status: RecoveryStatus.unknown,
    code: PreflightCheckCode.sharedMusicUnavailable,
  );
}
