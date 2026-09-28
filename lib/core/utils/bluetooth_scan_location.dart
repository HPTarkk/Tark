import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_sdk.dart';
import 'logger.dart';

/// Whether Bluetooth scanning can find anyone right now.
///
/// Android 6–11 returns no scan results at all while the system Location
/// switch is off, even with the permission granted. A search then stays
/// empty and reads as "nobody is hosting", which sends people to stand
/// closer instead of flipping the switch. Android 12+ scans with
/// `neverForLocation` and does not care.
Future<bool> bluetoothScanLocationReady({
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
      'bluetooth: location check failed error=${error.runtimeType}',
    );
    // Unknown is not "off": let the scan run and speak for itself.
    return true;
  }
}

/// Opens the system Location screen, where the switch the scan needs lives.
/// Rides the Wi-Fi join channel, which already carries this for the hotspot
/// joiner.
Future<void> openSystemLocationSettings() async {
  try {
    await const MethodChannel(
      'tark/wifi_join',
    ).invokeMethod<void>('openLocationSettings');
  } on PlatformException {
    // Some OEM builds have no such screen — nothing else to try.
  } on MissingPluginException {
    // Not Android.
  }
}
