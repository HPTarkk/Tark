import '../../../../core/recovery/recovery_check.dart';

/// Whether [checks] should stop the user from starting a ride.
///
/// Deliberately not [RecoveryCheck.isHealthy] — that predicate folds [warn]
/// into "unhealthy", which is right for the passive troubleshooting sheet
/// but wrong for a pre-ride gate, where a warning (phone-speaker route,
/// no helmet, HD unavailable) must still let "Start ride" through. Only
/// [RecoveryStatus.bad] blocks.
bool hasBlockingFailure(List<RecoveryCheck> checks) =>
    checks.any((c) => c.status == RecoveryStatus.bad);

/// Whether every row is at least resolved to something other than a
/// warning — used to decide whether "Continue anyway" is the honest label
/// or plain "Start ride" reads better.
bool hasOnlyWarnings(List<RecoveryCheck> checks) =>
    !hasBlockingFailure(checks) &&
    checks.any((c) => c.status == RecoveryStatus.warn);
