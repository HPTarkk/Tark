import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../audio/domain/entity/audio_route.dart';
import '../entity/preflight_check_code.dart';

/// Check 2 — playback/output route. A phone-speaker route is a [warn] with
/// no hard block ("Continue anyway" is the sheet-level CTA, not a per-row
/// action — desk/dev use still has to work); [AudioRoute.unknown] (no
/// channel to ask, or the platform couldn't say — all of iOS today) never
/// blocks either.
RecoveryCheck routeReadinessCheck({
  required AppLocalizations s,
  required AudioRoute route,
}) {
  switch (route) {
    case AudioRoute.bluetoothHeadset:
      return RecoveryCheck(
        label: s.preflight_check_headset,
        detail: s.preflight_route_bluetooth,
        status: RecoveryStatus.ok,
        code: PreflightCheckCode.routeBluetooth,
      );
    case AudioRoute.wired:
      return RecoveryCheck(
        label: s.preflight_check_headset,
        detail: s.preflight_route_wired,
        status: RecoveryStatus.ok,
        code: PreflightCheckCode.routeWired,
      );
    case AudioRoute.builtInSpeaker:
      return RecoveryCheck(
        label: s.preflight_check_headset,
        detail: s.preflight_route_speaker,
        status: RecoveryStatus.warn,
        code: PreflightCheckCode.routePhoneSpeaker,
      );
    case AudioRoute.unknown:
      return RecoveryCheck(
        label: s.preflight_check_headset,
        detail: s.preflight_route_unknown,
        status: RecoveryStatus.unknown,
        code: PreflightCheckCode.routeUnknown,
      );
  }
}
