import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/entity/transport_capability_advertisement.dart';

/// Reads only locally-proven transport-planning evidence from Android.
///
/// A missing plugin, unavailable battery reading, malformed platform response,
/// or any non-Android platform returns `null`. Callers must treat that as
/// unknown/ineligible evidence rather than inventing defaults.
abstract final class TransportCapabilityReader {
  static const _channel = MethodChannel('tark/transport_capabilities');

  /// Whether this phone should be the one to host, as it tells the others.
  ///
  /// Set once at start-up. Every reading that leaves this phone, the
  /// heartbeat included, carries it, so the others vote with the same answer
  /// this phone votes with. When the heartbeat always sent "no", a phone
  /// that could host on top of its Wi-Fi elected itself while the other phone
  /// elected itself on battery, and both raised an access point (2026-10-16).
  static Future<bool> Function()? hostingPreference;

  static Future<TransportCapabilityAdvertisement?> current({
    bool? prefersHotspotHost,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('snapshot');
      return decodeSnapshot(
        raw,
        prefersHotspotHost:
            prefersHotspotHost ?? await _readHostingPreference(),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> _readHostingPreference() async {
    final read = hostingPreference;
    if (read == null) return false;
    try {
      return await read();
    } catch (_) {
      return false;
    }
  }

  @visibleForTesting
  static TransportCapabilityAdvertisement? decodeSnapshot(
    Map<Object?, Object?>? raw, {
    bool prefersHotspotHost = false,
  }) {
    if (raw == null) return null;
    final canHostHotspot = raw['canHostHotspot'];
    final bluetoothSupported = raw['bluetoothSupported'];
    final backgroundReady = raw['backgroundReady'];
    final batteryPercent = raw['batteryPercent'];
    if (canHostHotspot is! bool ||
        bluetoothSupported is! bool ||
        backgroundReady is! bool ||
        batteryPercent is! int ||
        batteryPercent < 0 ||
        batteryPercent > 100) {
      return null;
    }
    return TransportCapabilityAdvertisement(
      canHostHotspot: canHostHotspot,
      bluetoothSupported: bluetoothSupported,
      backgroundReady: backgroundReady,
      batteryPercent: batteryPercent,
      prefersHotspotHost: prefersHotspotHost,
    );
  }
}
