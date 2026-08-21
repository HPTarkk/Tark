import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_action.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../data/mic_probe.dart';
import '../entity/preflight_check_code.dart';

/// Check 1 — converts a [MicProbeOutcome] into the row Preflight shows.
///
/// [retry] re-runs [MicProbe.run] and updates the sheet's state — wiring it
/// is the orchestrator's job (checkpoint 5); this function only decides what
/// to show for a given outcome, so it stays testable without a running
/// engine.
RecoveryCheck micCheck({
  required AppLocalizations s,
  required MicProbeOutcome outcome,
  required Future<void> Function() retry,
}) {
  switch (outcome) {
    case MicProbeOutcome.permissionDenied:
      return RecoveryCheck(
        label: s.preflight_check_mic,
        detail: s.preflight_mic_permission_denied,
        status: RecoveryStatus.bad,
        code: PreflightCheckCode.micPermissionDenied,
        actions: [
          RecoveryAction(label: s.fix_allow_mic, isPrimary: true, run: retry),
          RecoveryAction(label: s.open_settings, run: openAppSettings),
        ],
      );
    case MicProbeOutcome.noFrames:
      return RecoveryCheck(
        label: s.preflight_check_mic,
        detail: s.preflight_mic_no_frames,
        status: RecoveryStatus.bad,
        code: PreflightCheckCode.micNoFrames,
        actions: [
          RecoveryAction(
            label: s.fix_restart_mic,
            isPrimary: true,
            run: retry,
          ),
        ],
      );
    case MicProbeOutcome.ok:
      return RecoveryCheck(
        label: s.preflight_check_mic,
        detail: s.preflight_mic_ok,
        status: RecoveryStatus.ok,
        code: PreflightCheckCode.micOk,
      );
  }
}
