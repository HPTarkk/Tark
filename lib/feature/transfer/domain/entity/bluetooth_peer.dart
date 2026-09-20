import 'package:equatable/equatable.dart';

/// A nearby Bluetooth device discovered while scanning to join a host.
class BluetoothPeer extends Equatable {
  final String id;
  final String name;

  /// Signal strength in dBm at discovery time (higher = closer), null when
  /// the transport didn't report one. Refreshed while scanning.
  final int? rssi;

  /// True when this device is hosting from inside the app.
  final bool isAppHost;

  /// True only when native BLE service-data matched the one-way digest derived
  /// from the scanned QR invitation. This is peer-selection evidence, not
  /// membership authentication; the signed Room exchange still follows.
  final bool rendezvousMatched;

  const BluetoothPeer({
    required this.id,
    required this.name,
    this.rssi,
    this.isAppHost = false,
    this.rendezvousMatched = false,
  });

  /// BLE peers carry a `ble:` id prefix (see BleBluetoothEngine); everything
  /// else is Bluetooth Classic.
  bool get isBle => id.startsWith('ble:');

  /// 0–4 bars for UI, derived from typical indoor/outdoor dBm ranges.
  int get signalBars {
    final value = rssi;
    if (value == null) return 0;
    if (value >= -60) return 4;
    if (value >= -70) return 3;
    if (value >= -80) return 2;
    return 1;
  }

  @override
  List<Object?> get props => [id, name, rssi, isAppHost, rendezvousMatched];
}
