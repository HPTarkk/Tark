import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../transfer/domain/entity/connection_health.dart';
import '../../../transfer/domain/service/transport_advisor.dart';
import '../entity/preflight_check_code.dart';

/// Check 4 — network/transport readiness.
///
/// [plan] is whatever `TransportAdvisor.plan()` already computed at the
/// Landing/onboarding call site — [ChannelPlan.blocked] (a pinned Wi-Fi with
/// no network) is a free hard-fail signal, no new plumbing needed.
/// [liveHealth] is null before any connection attempt (the normal Preflight
/// sheet runs pre-connect, so this is the common case — "local transport
/// ready" and "peer verified" are deliberately different questions, per the
/// issue's own split); once a session exists, `TransferRepository.connect()`
/// already reports [ConnectionHealth] uniformly across every transport
/// (Wi-Fi, hotspot, Bluetooth, guest all normalize onto it), so no
/// transport-specific branching is needed here.
RecoveryCheck transportReadinessCheck({
  required AppLocalizations s,
  required ChannelPlan plan,
  ConnectionHealth? liveHealth,
}) {
  if (plan.blocked) {
    return RecoveryCheck(
      label: s.preflight_check_connection,
      detail: s.preflight_transport_blocked,
      status: RecoveryStatus.bad,
      code: PreflightCheckCode.transportBlocked,
    );
  }
  if (liveHealth == null) {
    return RecoveryCheck(
      label: s.preflight_check_connection,
      detail: s.preflight_transport_not_attempted,
      status: RecoveryStatus.unknown,
      code: PreflightCheckCode.transportNotAttempted,
    );
  }
  return switch (liveHealth.status) {
    ConnectionHealthStatus.healthy ||
    ConnectionHealthStatus.degraded => RecoveryCheck(
      label: s.preflight_check_connection,
      detail: s.preflight_transport_ready,
      status: RecoveryStatus.ok,
      code: PreflightCheckCode.transportReady,
    ),
    ConnectionHealthStatus.reconnecting ||
    ConnectionHealthStatus.renegotiating => RecoveryCheck(
      label: s.preflight_check_connection,
      detail: s.preflight_transport_degraded,
      status: RecoveryStatus.warn,
      code: PreflightCheckCode.transportDegraded,
    ),
    ConnectionHealthStatus.down => RecoveryCheck(
      label: s.preflight_check_connection,
      detail: s.preflight_transport_down,
      status: RecoveryStatus.bad,
      code: PreflightCheckCode.transportDown,
    ),
  };
}
