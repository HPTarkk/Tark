import '../entity/bluetooth_connection_state.dart';
import '../entity/bluetooth_peer.dart';

/// Bluetooth-only connection-control surface, separate from [TransferRepository]
/// since establishing a 1-to-1 Bluetooth link (host/join, scan, pairing) has
/// no WiFi equivalent — WiFi mode never needs this.
abstract interface class BluetoothTransport {
  Stream<BluetoothConnectionState> get connectionState;

  /// The last state [connectionState] published, for a caller that arrives
  /// after it was published.
  ///
  /// [connectionState] is a broadcast stream, which discards everything it
  /// emits while nothing is listening — so a screen that opens *after* the
  /// link came up learns nothing from subscribing and would conclude there is
  /// no link at all. That failure has already cost this app three debug
  /// rounds once (see the classic auto-join history); it is not a shape to
  /// leave a second caller to rediscover.
  BluetoothConnectionState get currentConnectionState;

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

  /// Listens for one incoming connection, making sure the device also answers
  /// inquiries while it waits — a scanning joiner can see nothing else, and
  /// the server socket alone leaves the host invisible. The system is asked
  /// for discoverability only when a previous grant isn't still running.
  ///
  /// (The unattended re-listen after a mid-session drop deliberately does not
  /// come through here: that joiner re-dials by address, so it needs only the
  /// server socket, and a dialog would fire with nobody looking at the phone.)
  Future<void> startHosting();

  /// Whether other phones can currently find this one by scanning. Android
  /// discoverability is a time-limited grant, so a host that is still waiting
  /// can go quietly invisible; iOS advertises over BLE instead and is always
  /// findable while hosting.
  Future<bool> get isHostDiscoverable;

  /// Re-asks the system to make this device findable, resolving with the
  /// user's answer. No-op (true) where discoverability isn't a concept.
  Future<bool> requestHostDiscoverable();

  /// Scans for nearby hosts. Callers should call [cancelDiscovery] once done.
  Stream<BluetoothPeer> scanForHosts();

  Future<void> connectToHost(BluetoothPeer peer);

  void cancelDiscovery();

  /// Tears down any hosting/scanning/connection state without disposing the
  /// underlying repository (e.g. user backs out of the connect screen).
  void reset();
}
