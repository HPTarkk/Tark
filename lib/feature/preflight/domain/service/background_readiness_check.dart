import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_action.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../entity/preflight_check_code.dart';

/// Check 6 — background execution readiness.
///
/// A single combined "Background mode" row (worst-of status), reading
/// signals `SessionKeepAlive` and `permission_handler` already expose —
/// [notificationRequired]/[notificationGranted] gate on SDK <33 the same way
/// `permissions_page.dart`'s hotspot-permission pick does, and
/// [batteryExempt]/[isMiui] are exactly `background_permission_banner.dart`'s
/// own combination (Autostart is an *extra* action offered alongside the
/// battery-exemption prompt, not an independent failure — MIUI alone with
/// the exemption already granted is not flagged). Both sub-problems are
/// [RecoveryStatus.warn] only, never [RecoveryStatus.bad], per the issue's
/// explicit blocking policy — an OS setting the app can't force is a warning
/// with a fix offered, not a wall. No independent signal exists for wake/
/// Wi-Fi lock readiness (`SessionKeepAliveWakeLock` only starts/stops, it
/// doesn't expose a query) — deliberately not fabricated here.
RecoveryCheck backgroundReadinessCheck({
  required AppLocalizations s,
  required bool notificationRequired,
  required bool notificationGranted,
  required bool batteryExempt,
  required bool isMiui,
  required Future<void> Function() requestNotification,
  required Future<void> Function() requestBatteryExemption,
  required Future<void> Function() openAutoStartSettings,
}) {
  final notificationProblem = notificationRequired && !notificationGranted;
  final batteryProblem = !batteryExempt;

  if (!notificationProblem && !batteryProblem) {
    return RecoveryCheck(
      label: s.preflight_check_background,
      detail: s.preflight_background_ok,
      status: RecoveryStatus.ok,
      code: PreflightCheckCode.backgroundOk,
    );
  }

  return RecoveryCheck(
    label: s.preflight_check_background,
    detail: batteryProblem
        ? s.preflight_background_restricted
        : s.preflight_background_notification_denied,
    status: RecoveryStatus.warn,
    code: batteryProblem
        ? PreflightCheckCode.backgroundBatteryRestricted
        : PreflightCheckCode.backgroundNotificationDenied,
    actions: [
      if (batteryProblem)
        RecoveryAction(
          label: s.background_allow,
          isPrimary: true,
          run: requestBatteryExemption,
        ),
      if (batteryProblem && isMiui)
        RecoveryAction(
          label: s.background_autostart,
          run: openAutoStartSettings,
        ),
      if (notificationProblem)
        RecoveryAction(
          label: s.preflight_fix_allow_notifications,
          isPrimary: !batteryProblem,
          run: requestNotification,
        ),
    ],
  );
}
