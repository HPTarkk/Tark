import 'package:flutter/services.dart';

/// Android API level, fetched natively once and cached for the app's
/// lifetime (it can't change while running).
///
/// Rides the Bluetooth server method channel because MainActivity registers
/// that handler unconditionally at engine startup — there is no dedicated
/// device-info channel, and one integer doesn't justify a plugin. Throws on
/// non-Android platforms or channel failure; callers pick their own fallback.
abstract final class AndroidSdk {
  static const _methods = MethodChannel('tark/bluetooth_server/methods');
  static int? _cached;

  static Future<int> version() async =>
      _cached ??= await _methods.invokeMethod<int>('sdkInt') ?? 0;
}
