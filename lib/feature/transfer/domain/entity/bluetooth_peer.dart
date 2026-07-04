import 'package:equatable/equatable.dart';

/// A nearby Bluetooth device discovered while scanning to join a host.
class BluetoothPeer extends Equatable {
  final String id;
  final String name;

  /// Signal strength in dBm at discovery time (higher = closer), null when
  /// the transport didn't report one. Refreshed while scanning.
  final int? rssi;

  const BluetoothPeer({required this.id, required this.name, this.rssi});

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
  List<Object?> get props => [id, name, rssi];
}
