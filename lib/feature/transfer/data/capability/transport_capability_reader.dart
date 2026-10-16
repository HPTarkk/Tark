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

  /// Whether this phone is holding an access point up and the others reach
  /// it there, so a peer hearing it over Wi-Fi is on that access point.
  /// Set once at start-up, like [hostingPreference], and carried on every
  /// reading so a phone joined to the access point knows the network it is
  /// on is the Room's own rather than some router. See [carriesOnAccessPoint].
  static Future<bool> Function()? hostingNow;

  static DateTime? _gaveUpMoveUntil;

  /// How long a phone keeps telling the others it gave up on a move. Long
  /// enough for a few heartbeats to get through, short enough that a peer on
  /// an older build (which rejects unknown flags) misses this phone's
  /// capabilities only briefly.
  static const gaveUpMoveFor = Duration(seconds: 12);

  /// Whether this phone has just given up on moving the Room to a hotspot.
  static bool get gaveUpMove {
    final until = _gaveUpMoveUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// Tells the other phones, on every heartbeat for [gaveUpMoveFor], that the
  /// move failed here, so they stop waiting for it and show the same screen.
  static void signalGaveUpMove() =>
      _gaveUpMoveUntil = DateTime.now().add(gaveUpMoveFor);

  /// A new attempt starts clean.
  static void clearGaveUpMove() => _gaveUpMoveUntil = null;

  /// Whether a phone [hosting] an access point carries the Room on it.
  ///
  /// On no other Wi-Fi ([station] null) it can only be heard over its own
  /// access point. Joined to a router as well — Android 12 rejoins the home
  /// Wi-Fi beside a hotspot by itself — it carries the Room when a peer is
  /// heard on a subnet other than the router's. Saying "no" whenever a router
  /// was present is what left the other phone, sitting on this one's access
  /// point, treating it as a router and moving the pair off it (2026-10-16:
  /// the host rejoined the home Wi-Fi 30 s into the call). A peer heard only
  /// on the router's subnet means the access point is a leftover nobody uses.
  static bool carriesOnAccessPoint({
    required bool hosting,
    required String? station,
    required Iterable<String> peers,
  }) {
    if (!hosting) return false;
    if (station == null) return true;
    final router = _subnetOf(station);
    return peers.any((peer) {
      final subnet = _subnetOf(peer);
      return subnet != null && subnet != router;
    });
  }

  static String? _subnetOf(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return null;
    return parts.take(3).join('.');
  }

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
        hostingAccessPoint: await _readHostingNow(),
        gaveUpMove: gaveUpMove,
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

  static Future<bool> _readHostingNow() async {
    final read = hostingNow;
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
    bool hostingAccessPoint = false,
    bool gaveUpMove = false,
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
      hostingAccessPoint: hostingAccessPoint,
      gaveUpMove: gaveUpMove,
    );
  }
}
