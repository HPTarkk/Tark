import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../entity/preflight_check_code.dart';

/// Check 5 — peer reachability/bidirectional audibility.
///
/// [unheardByPeers] is null before any peer exists (the normal Preflight
/// sheet runs before joining, so this is the common case — always
/// [RecoveryStatus.unknown], the issue's own named warning-only case, never
/// blocking). Once connected, this reads the exact same signal
/// `WalkieTalkieCubit` already derives from `PresencePacket.heardIds` (see
/// `_noteAudibility`/`_checkAudibility`) — no new packet type or side
/// channel. Deliberately [warn], not [bad], even once a peer is known but
/// hasn't confirmed yet: unlike the mid-channel troubleshooting sheet (where
/// this signal has already been graded stale by the time it shows), Preflight
/// asks the question the moment a peer appears, and "hasn't said yet" isn't
/// failure — see the issue's blocking policy ("peer not yet present ... is
/// warning/continue-allowed").
RecoveryCheck peerReachabilityCheck({
  required AppLocalizations s,
  bool? unheardByPeers,
}) {
  if (unheardByPeers == null) {
    return RecoveryCheck(
      label: s.preflight_check_peer_reachability,
      detail: s.preflight_peer_not_present,
      status: RecoveryStatus.unknown,
      code: PreflightCheckCode.peerNotPresent,
    );
  }
  if (unheardByPeers) {
    return RecoveryCheck(
      label: s.preflight_check_peer_reachability,
      detail: s.preflight_peer_unconfirmed,
      status: RecoveryStatus.warn,
      code: PreflightCheckCode.peerUnconfirmed,
    );
  }
  return RecoveryCheck(
    label: s.preflight_check_peer_reachability,
    detail: s.preflight_peer_confirmed,
    status: RecoveryStatus.ok,
    code: PreflightCheckCode.peerConfirmed,
  );
}
