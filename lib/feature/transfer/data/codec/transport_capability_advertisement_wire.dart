import 'dart:typed_data';

import '../../domain/entity/transport_capability_advertisement.dart';

/// Fixed, bounded record for optional Room transport capability evidence.
///
/// This codec intentionally does not choose its wire carrier. In particular,
/// do not append this record directly to the legacy Presence body: older
/// Presence decoders interpret byte 4 as the heard-id count and may reject the
/// whole packet when additional bytes follow. Carrier wiring is a separate
/// compatibility-sensitive step and must prove mixed-version behavior before
/// emission is enabled.
///
/// Once a compatible carrier supplies this record, unknown marker/version,
/// truncation, unknown flags, or an invalid bounded battery value all fail
/// closed to `null`. This does not introduce a packet-v2 rewrite.
abstract final class TransportCapabilityAdvertisementWire {
  static const marker = 0x54; // 'T' for transport capability.
  static const version = 2;

  /// marker, version, flags, battery, Android API level, then the first
  /// install time as four big-endian bytes of seconds since the epoch.
  static const encodedLength = 9;

  static const _canHostHotspot = 1 << 0;
  static const _bluetoothSupported = 1 << 1;
  static const _backgroundReady = 1 << 2;
  static const _prefersHotspotHost = 1 << 3;

  /// Set only while the phone is actually hosting.
  static const _hostingAccessPoint = 1 << 4;

  /// Set only for a few seconds after this phone gave up on a move.
  static const _gaveUpMove = 1 << 5;
  static const _knownFlags =
      _canHostHotspot |
      _bluetoothSupported |
      _backgroundReady |
      _prefersHotspotHost |
      _hostingAccessPoint |
      _gaveUpMove;

  static Uint8List encode(TransportCapabilityAdvertisement value) {
    var flags = 0;
    if (value.canHostHotspot) flags |= _canHostHotspot;
    if (value.bluetoothSupported) flags |= _bluetoothSupported;
    if (value.backgroundReady) flags |= _backgroundReady;
    if (value.prefersHotspotHost) flags |= _prefersHotspotHost;
    if (value.hostingAccessPoint) flags |= _hostingAccessPoint;
    if (value.gaveUpMove) flags |= _gaveUpMove;
    final installed = value.installedAt.clamp(0, 0xFFFFFFFF);
    return Uint8List.fromList([
      marker,
      version,
      flags,
      value.batteryPercent,
      value.androidSdk.clamp(0, 255),
      (installed >> 24) & 0xFF,
      (installed >> 16) & 0xFF,
      (installed >> 8) & 0xFF,
      installed & 0xFF,
    ]);
  }

  /// Decodes exactly one optional record beginning at [offset].
  ///
  /// Extra bytes after the known record are ignored so a compatible carrier
  /// may grow additively. Unknown flag bits are rejected rather than silently
  /// interpreted as eligibility evidence.
  static TransportCapabilityAdvertisement? decode(Uint8List bytes, int offset) {
    if (offset < 0 || bytes.length - offset < encodedLength) return null;
    if (bytes[offset] != marker || bytes[offset + 1] != version) return null;

    final flags = bytes[offset + 2];
    if ((flags & ~_knownFlags) != 0) return null;
    final battery = bytes[offset + 3];
    if (battery > 100) return null;
    final installed =
        (bytes[offset + 5] << 24) |
        (bytes[offset + 6] << 16) |
        (bytes[offset + 7] << 8) |
        bytes[offset + 8];

    return TransportCapabilityAdvertisement(
      canHostHotspot: (flags & _canHostHotspot) != 0,
      bluetoothSupported: (flags & _bluetoothSupported) != 0,
      backgroundReady: (flags & _backgroundReady) != 0,
      prefersHotspotHost: (flags & _prefersHotspotHost) != 0,
      hostingAccessPoint: (flags & _hostingAccessPoint) != 0,
      gaveUpMove: (flags & _gaveUpMove) != 0,
      batteryPercent: battery,
      androidSdk: bytes[offset + 4],
      installedAt: installed,
    );
  }
}
