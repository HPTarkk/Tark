import '../entity/bluetooth_connection_state.dart';
import '../entity/bluetooth_peer.dart';

/// Bluetooth-only connection-control surface, separate from [TransferRepository]
/// since establishing a 1-to-1 Bluetooth link (host/join, scan, pairing) has
/// no WiFi equivalent — WiFi mode never needs this.
abstract interface class BluetoothTransport {
  Stream<BluetoothConnectionState> get connectionState;

  /// Emits whether BLE host advertising is active. `false` means iPhones can't
  /// discover this device over Bluetooth LE (the chipset lacks the peripheral
  /// role), so the UI should steer cross-platform users to the Wi-Fi hotspot
  /// bridge. Only meaningful while hosting.
  Stream<bool> get bleAdvertising;

  /// Makes this device discoverable and listens for one incoming connection.
  Future<void> startHosting();

  /// Scans for nearby hosts. Callers should call [cancelDiscovery] once done.
  Stream<BluetoothPeer> scanForHosts();

  Future<void> connectToHost(BluetoothPeer peer);

  void cancelDiscovery();

  /// Tears down any hosting/scanning/connection state without disposing the
  /// underlying repository (e.g. user backs out of the connect screen).
  void reset();
}
