import 'package:permission_handler/permission_handler.dart';

import '../utils/permission_queue.dart';

/// The platform side of a permission flow, behind an interface so the flow
/// can be driven by a fake in tests.
abstract interface class PermissionBackend {
  /// Current status of each of [permissions], without prompting.
  Future<Map<Permission, PermissionStatus>> statuses(
    List<Permission> permissions,
  );

  /// Raises the operating system's own dialog for [permissions].
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  );

  /// Opens this app's page in the system settings.
  Future<bool> openSettings();
}

/// [PermissionBackend] over `permission_handler`.
///
/// Every request goes through [PermissionQueue]: Android drops a second
/// in-flight request and never answers it, so nothing here may bypass the
/// queue. Status reads are not requests and need no slot.
class PluginPermissionBackend implements PermissionBackend {
  const PluginPermissionBackend();

  @override
  Future<Map<Permission, PermissionStatus>> statuses(
    List<Permission> permissions,
  ) async => {for (final p in permissions) p: await p.status};

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) => PermissionQueue.run(() => permissions.request());

  @override
  Future<bool> openSettings() => openAppSettings();
}

extension PermissionStatusReading on PermissionStatus {
  /// Good enough to proceed: a full grant, or iOS's limited/provisional ones.
  bool get isUsable => isGranted || isLimited || isProvisional;

  /// The operating system will not show its dialog for this again; only the
  /// system settings can change it now. permission_handler already folds
  /// Android's "should show rationale" answer into [isPermanentlyDenied].
  bool get isBlocked => isPermanentlyDenied || isRestricted;
}
