import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/utils/android_sdk.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/permission_queue.dart';

typedef RoomInvitePermissionGate = Future<bool> Function();
typedef RoomInvitePermissionRequest =
    Future<Map<Permission, PermissionStatus>> Function(
      List<Permission> permissions,
    );

/// Requests the runtime permissions a Room's proximity invitation needs, on
/// whichever end of it this phone is.
///
/// The issuer advertises and listens; the joiner scans and dials. Both are
/// entry points of their own — the regular Bluetooth page already has this
/// gate, but relying on that page having been visited makes a clean install
/// fail before a QR can be shown, or scan for a host it can never see.
Future<bool> ensureRoomInviteBluetoothPermissions({
  TargetPlatform? platform,
  Future<int> Function()? sdkVersion,
  RoomInvitePermissionRequest? requestPermissions,
}) async {
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return true;
  }

  final permissions = <Permission>[
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
  ];
  try {
    if (await (sdkVersion ?? AndroidSdk.version)() < 31) {
      permissions.add(Permission.locationWhenInUse);
    }
  } catch (error) {
    Logger.diagnostic(
      'room_invite: sdk lookup failed error=${error.runtimeType}',
    );
    // Match the established Bluetooth page: assume Android S+ when the SDK
    // lookup itself fails, so modern devices are not asked for location.
  }

  final request =
      requestPermissions ?? (List<Permission> values) => values.request();
  final statuses = await PermissionQueue.run(() => request(permissions));
  return permissions.every(
    (permission) => statuses[permission]?.isGranted == true,
  );
}

typedef RoomScanLocationGate = Future<bool> Function();

/// Whether Bluetooth scanning can find anyone right now.
///
/// Android 6–11 returns no scan results at all while the system Location
/// switch is off, even with the permission granted. The rendezvous then
/// times out and reads as "couldn't find their phone", which sends people to
/// stand closer instead of flipping the switch. Android 12+ scans with
/// `neverForLocation` and does not care.
Future<bool> roomScanLocationReady({
  TargetPlatform? platform,
  Future<int> Function()? sdkVersion,
  Future<ServiceStatus> Function()? locationService,
}) async {
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return true;
  }
  try {
    if (await (sdkVersion ?? AndroidSdk.version)() >= 31) return true;
    final status =
        await (locationService ??
            () => Permission.locationWhenInUse.serviceStatus)();
    return status != ServiceStatus.disabled;
  } catch (error) {
    Logger.diagnostic(
      'room_join: location check failed error=${error.runtimeType}',
    );
    // Unknown is not "off": let the scan run and speak for itself.
    return true;
  }
}
