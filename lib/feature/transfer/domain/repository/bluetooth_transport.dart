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

  /// Whether scanning/connecting can start right now without surfacing any
  /// system dialog. Android: requires the adapter to already be ON (scanning
  /// with it off pops the enable dialog). iOS has no such dialog, so this is
  /// always true there. Background auto-reconnect checks this so a
  /// subsequent-session connect never interrupts the user.
  Future<bool> get isAdapterReady;

  /// Listens for one incoming connection. When [discoverable] is true (the
  /// manual "Host" tap) it also pops the system "make discoverable" dialog so
  /// a fresh scan can find this device; when false (hands-free auto-host of a
  /// remembered session) it skips that dialog — the remembered joiner re-dials
  /// by address, which only needs the server listening, not scan visibility.
  Future<void> startHosting({bool discoverable = true});

  /// Scans for nearby hosts. Callers should call [cancelDiscovery] once done.
  Stream<BluetoothPeer> scanForHosts();

  Future<void> connectToHost(BluetoothPeer peer);

  void cancelDiscovery();

  /// Tears down any hosting/scanning/connection state without disposing the
  /// underlying repository (e.g. user backs out of the connect screen).
  void reset();
}
