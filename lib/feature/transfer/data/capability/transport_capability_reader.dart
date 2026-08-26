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

  static Future<TransportCapabilityAdvertisement?> current({
    bool prefersHotspotHost = false,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('snapshot');
      return decodeSnapshot(raw, prefersHotspotHost: prefersHotspotHost);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
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
