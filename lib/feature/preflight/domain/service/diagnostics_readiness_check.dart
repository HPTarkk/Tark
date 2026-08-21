import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../entity/preflight_check_code.dart';

/// Check 8 — diagnostics readiness: can this session record the evidence a
/// support report would need (negotiated route/profile/recovery events)?
///
/// Not one of the sheet's six visible rows (Headset/Microphone/Connection/
/// Background mode/HD Voice/Shared Music) — it exists for Preflight's own
/// diagnostics log, not as a user-facing gate, so [isEnabled]/[isPersisting]
/// being false is never [RecoveryStatus.bad]: nothing here is something the
/// user can act on mid-Preflight, and logging is not a ride-readiness
/// requirement in the issue's own blocking policy.
RecoveryCheck diagnosticsReadinessCheck({
  required AppLocalizations s,
  required bool isEnabled,
  required bool isPersisting,
}) {
  if (!isEnabled) {
    return RecoveryCheck(
      label: s.preflight_check_diagnostics,
      detail: s.preflight_diagnostics_disabled,
      status: RecoveryStatus.unknown,
      code: PreflightCheckCode.diagnosticsDisabled,
    );
  }
  if (!isPersisting) {
    return RecoveryCheck(
      label: s.preflight_check_diagnostics,
      detail: s.preflight_diagnostics_memory_only,
      status: RecoveryStatus.warn,
      code: PreflightCheckCode.diagnosticsMemoryOnly,
    );
  }
  return RecoveryCheck(
    label: s.preflight_check_diagnostics,
    detail: s.preflight_diagnostics_ok,
    status: RecoveryStatus.ok,
    code: PreflightCheckCode.diagnosticsOk,
  );
}
