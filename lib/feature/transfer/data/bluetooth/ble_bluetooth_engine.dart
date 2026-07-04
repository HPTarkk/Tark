import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_peer.dart';
import 'length_prefixed_framer.dart';

/// Tark's custom GATT service. The host (peripheral) advertises this
/// service; joiners (centrals) filter scans on it so only Tark hosts
/// show up.
final kWakiServiceUuid = UUID.fromString('C0DE0001-57A1-4B1E-9A0B-2D6577616B69');

/// Client → host stream (central writes without response).
final kWakiRxCharUuid = UUID.fromString('C0DE0002-57A1-4B1E-9A0B-2D6577616B69');

/// Host → client stream (peripheral notifies).
final kWakiTxCharUuid = UUID.fromString('C0DE0003-57A1-4B1E-9A0B-2D6577616B69');

/// BLE engine for 1-to-1 sessions — the transport that works on iOS (Apple
/// forbids Classic Bluetooth), and cross-platform iPhone↔Android.
///
/// Roles map onto GATT: "start session" = peripheral advertising
/// [kWakiServiceUuid]; "join" = central scanning for it. Data flows as
/// write-without-response (client→host) and notifications (host→client).
/// BLE ATT has per-packet size limits, so messages are length-prefix framed
/// ([frameMessage]) and chunked to the negotiated maximum; ATT guarantees
/// ordering, so the [FrameReassembler] on the far side restores message
/// boundaries. Bandwidth is enough because audio is Opus (~40-80 bytes per
/// 20 ms frame), never raw PCM.
///
/// Unlike [ClassicBluetoothEngine], [input] emits complete reassembled
/// messages and [write] takes unframed payloads — framing is internal.
class BleBluetoothEngine {
  CentralManager? _central;
  PeripheralManager? _peripheral;

  final _framer = FrameReassembler();

  final _inputController = StreamController<Uint8List>.broadcast();
  final _peerConnectedController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _closedController = StreamController<void>.broadcast();

  /// Complete messages received from the connected peer, regardless of role.
  Stream<Uint8List> get input => _inputController.stream;

  /// Fires with the peer's UUID once a connection is established.
  Stream<String> get onPeerConnected => _peerConnectedController.stream;

  Stream<String> get onError => _errorController.stream;

  Stream<void> get onClosed => _closedController.stream;

  // ── Host (peripheral) state ────────────────────────────────────────────
  bool _hosting = false;
  Central? _hostPeerCentral;
  GATTCharacteristic? _hostTxChar;
  final List<StreamSubscription<dynamic>> _hostSubs = [];

  // ── Join (central) state ───────────────────────────────────────────────
  final Map<String, Peripheral> _discovered = {};
  Peripheral? _clientPeripheral;
  GATTCharacteristic? _clientRxChar; // we write here
  final List<StreamSubscription<dynamic>> _clientSubs = [];
  StreamController<BluetoothPeer>? _scanController;

  // Sequentialize chunked writes so two concurrent write() calls can't
  // interleave their chunks inside one framed message. Audio arrives at a
  // fixed 50 packets/s regardless of what the link can carry, so when the
  // queue backs up, new packets are DROPPED instead of enqueued — stale
  // audio is worse than lost audio (the receiver conceals losses, but
  // queued backlog becomes ever-growing latency).
  Future<void> _writeQueue = Future<void>.value();
  int _pendingWrites = 0;
  static const _maxPendingWrites = 8;

  bool get isConnected =>
      _hostPeerCentral != null || (_clientPeripheral != null && _clientRxChar != null);

  // ── Managers ───────────────────────────────────────────────────────────

  CentralManager get _requireCentral => _central ??= CentralManager();
  PeripheralManager get _requirePeripheral => _peripheral ??= PeripheralManager();

  Future<void> _ready(BluetoothLowEnergyManager manager) async {
    // Android needs runtime permissions granted through the plugin as well;
    // a no-op elsewhere (throws UnsupportedError, which we ignore). On iOS,
    // merely creating the manager is what triggers the system Bluetooth
    // permission prompt — which is why callers must reach this point even
    // before any permission looks granted.
    try {
      await manager.authorize();
    } catch (_) {}
    if (manager.state == BluetoothLowEnergyState.poweredOn) return;
    // Fail fast on terminal states instead of waiting out the timeout:
    // unauthorized (user denied the iOS prompt) and unsupported can only
    // be fixed outside the app.
    if (manager.state == BluetoothLowEnergyState.unauthorized ||
        manager.state == BluetoothLowEnergyState.unsupported) {
      throw StateError('Bluetooth unavailable (${manager.state})');
    }
    try {
      final settled = await manager.stateChanged
          .map((e) => e.state)
          .firstWhere((s) =>
              s == BluetoothLowEnergyState.poweredOn ||
              s == BluetoothLowEnergyState.unauthorized ||
              s == BluetoothLowEnergyState.unsupported)
          .timeout(const Duration(seconds: 8));
      if (settled != BluetoothLowEnergyState.poweredOn) {
        throw StateError('Bluetooth unavailable ($settled)');
      }
    } on TimeoutException {
      throw StateError('Bluetooth is not powered on (${manager.state})');
    }
  }

  // ── Host ───────────────────────────────────────────────────────────────

  Future<void> startHosting({required String name}) async {
    try {
      final manager = _requirePeripheral;
      await _ready(manager);
      await _cancelHostSubs();
      _hosting = true;
      _framer.reset();

      final txChar = GATTCharacteristic.mutable(
        uuid: kWakiTxCharUuid,
        properties: [GATTCharacteristicProperty.notify],
        permissions: [GATTCharacteristicPermission.read],
        descriptors: [],
      );
      final rxChar = GATTCharacteristic.mutable(
        uuid: kWakiRxCharUuid,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [
          GATTCharacteristicPermission.read,
          GATTCharacteristicPermission.write,
        ],
        descriptors: [],
      );
      _hostTxChar = txChar;

      _hostSubs.add(manager.characteristicWriteRequested.listen((e) async {
        try {
          await manager.respondWriteRequest(e.request);
        } catch (_) {}
        if (e.characteristic.uuid == kWakiRxCharUuid) {
          for (final message in _framer.addBytes(e.request.value)) {
            _inputController.add(message);
          }
        }
      }));

      // A central subscribing to the TX characteristic is the moment the
      // session becomes usable in both directions — that's "connected".
      // Unsubscribe (or Android's explicit disconnect event) ends it.
      _hostSubs.add(manager.characteristicNotifyStateChanged.listen((e) {
        if (e.characteristic.uuid != kWakiTxCharUuid) return;
        if (e.state) {
          _hostPeerCentral = e.central;
          _peerConnectedController.add('ble:${e.central.uuid}');
        } else if (_hostPeerCentral?.uuid == e.central.uuid) {
          _hostPeerCentral = null;
          _framer.reset();
          _closedController.add(null);
        }
      }));

      try {
        _hostSubs.add(manager.connectionStateChanged.listen((e) {
          if (e.state == ConnectionState.disconnected &&
              _hostPeerCentral?.uuid == e.central.uuid) {
            _hostPeerCentral = null;
            _framer.reset();
            _closedController.add(null);
          }
        }));
      } on UnsupportedError {
        // iOS: unsubscribe events above cover disconnects.
      }

      await manager.removeAllServices();
      await manager.addService(GATTService(
        uuid: kWakiServiceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [txChar, rxChar],
      ));
      try {
        await manager.startAdvertising(Advertisement(
          name: name,
          serviceUUIDs: [kWakiServiceUuid],
        ));
      } catch (_) {
        // A 128-bit service UUID plus a name easily overflows the 31-byte
        // legacy advertisement (ADVERTISE_FAILED_DATA_TOO_LARGE on
        // Android). The service UUID is what joiners actually filter on —
        // retry without the name rather than not advertising at all.
        await manager.startAdvertising(Advertisement(
          serviceUUIDs: [kWakiServiceUuid],
        ));
      }
    } catch (e) {
      Logger.log('BLE startHosting failed: $e');
      _errorController.add('$e');
    }
  }

  Future<void> stopHosting() async {
    _hosting = false;
    _hostPeerCentral = null;
    _hostTxChar = null;
    await _cancelHostSubs();
    try {
      await _peripheral?.stopAdvertising();
      await _peripheral?.removeAllServices();
    } catch (e) {
      Logger.log('BLE stopHosting: $e');
    }
  }

  Future<void> _cancelHostSubs() async {
    for (final sub in _hostSubs) {
      await sub.cancel();
    }
    _hostSubs.clear();
  }

  // ── Join (client) ──────────────────────────────────────────────────────

  Stream<BluetoothPeer> scanForHosts() {
    final controller = StreamController<BluetoothPeer>.broadcast();
    _scanController?.close();
    _scanController = controller;

    () async {
      try {
        final manager = _requireCentral;
        await _ready(manager);
        _clientSubs.add(manager.discovered.listen((e) {
          final id = e.peripheral.uuid.toString();
          _discovered[id] = e.peripheral;
          String? name;
          try {
            name = e.advertisement.name;
          } catch (_) {}
          if (controller.isClosed) return;
          controller.add(BluetoothPeer(
            id: 'ble:$id',
            name: name?.isNotEmpty == true ? name! : 'Tark (BLE)',
            rssi: e.rssi,
          ));
        }));
        await manager.startDiscovery(serviceUUIDs: [kWakiServiceUuid]);
      } catch (e) {
        Logger.log('BLE scan failed: $e');
        _errorController.add('$e');
      }
    }();

    return controller.stream;
  }

  void cancelDiscovery() {
    _scanController?.close();
    _scanController = null;
    final central = _central;
    if (central != null) {
      central.stopDiscovery().catchError((Object e) {
        Logger.log('BLE stopDiscovery: $e');
      });
    }
  }

  Future<void> connectToHost(String id) async {
    try {
      final manager = _requireCentral;
      final peripheral = _discovered[id];
      if (peripheral == null) {
        _errorController.add('Peer no longer available');
        return;
      }
      cancelDiscovery();
      _framer.reset();

      _clientSubs.add(manager.connectionStateChanged.listen((e) {
        if (e.peripheral.uuid == peripheral.uuid &&
            e.state == ConnectionState.disconnected &&
            _clientPeripheral != null) {
          _clientPeripheral = null;
          _clientRxChar = null;
          _framer.reset();
          _closedController.add(null);
        }
      }));

      await manager.connect(peripheral);

      // Bigger ATT MTU = fewer chunks per frame. Android-only; harmless to
      // skip elsewhere (iOS negotiates its own maximum automatically).
      try {
        await manager.requestMTU(peripheral, mtu: 517);
      } catch (_) {}

      final services = await manager.discoverGATT(peripheral);
      final service = services.firstWhere(
        (s) => s.uuid == kWakiServiceUuid,
        orElse: () => throw StateError('Tark service not found on host'),
      );
      final txChar =
          service.characteristics.firstWhere((c) => c.uuid == kWakiTxCharUuid);
      final rxChar =
          service.characteristics.firstWhere((c) => c.uuid == kWakiRxCharUuid);

      _clientSubs.add(manager.characteristicNotified.listen((e) {
        if (e.peripheral.uuid != peripheral.uuid ||
            e.characteristic.uuid != kWakiTxCharUuid) {
          return;
        }
        for (final message in _framer.addBytes(e.value)) {
          _inputController.add(message);
        }
      }));
      await manager.setCharacteristicNotifyState(peripheral, txChar,
          state: true);

      _clientPeripheral = peripheral;
      _clientRxChar = rxChar;
      _peerConnectedController.add('ble:${peripheral.uuid}');
    } catch (e) {
      Logger.log('BLE connect failed: $e');
      _errorController.add('$e');
    }
  }

  // ── Unified write (picks whichever role is active) ─────────────────────

  /// Frames [payload], chunks it to the link's maximum, and sends it to the
  /// connected peer. Silently drops when no peer is connected.
  Future<void> write(Uint8List payload) {
    if (_pendingWrites >= _maxPendingWrites) return Future.value();
    _pendingWrites++;
    final task = _writeQueue.then((_) => _writeChunked(payload));
    // Keep the queue alive even when a write fails.
    _writeQueue = task.then<void>(
      (_) => _pendingWrites--,
      onError: (_) => _pendingWrites--,
    );
    return task;
  }

  Future<void> _writeChunked(Uint8List payload) async {
    final framed = frameMessage(payload);
    try {
      final central = _hostPeerCentral;
      final peripheral = _clientPeripheral;
      if (_hosting && central != null && _hostTxChar != null) {
        final maxLen = await _peripheral!.getMaximumNotifyLength(central);
        for (final chunk in _chunks(framed, maxLen)) {
          await _peripheral!
              .notifyCharacteristic(central, _hostTxChar!, value: chunk);
        }
      } else if (peripheral != null && _clientRxChar != null) {
        final maxLen = await _central!.getMaximumWriteLength(
          peripheral,
          type: GATTCharacteristicWriteType.withoutResponse,
        );
        for (final chunk in _chunks(framed, maxLen)) {
          await _central!.writeCharacteristic(
            peripheral,
            _clientRxChar!,
            value: chunk,
            type: GATTCharacteristicWriteType.withoutResponse,
          );
        }
      }
    } catch (e) {
      Logger.log('BLE write failed: $e');
    }
  }

  Iterable<Uint8List> _chunks(Uint8List bytes, int maxLen) sync* {
    final size = maxLen.clamp(20, 512);
    for (var offset = 0; offset < bytes.length; offset += size) {
      final end =
          offset + size < bytes.length ? offset + size : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }

  // ── Teardown ───────────────────────────────────────────────────────────

  Future<void> reset() async {
    cancelDiscovery();
    for (final sub in _clientSubs) {
      await sub.cancel();
    }
    _clientSubs.clear();
    final peripheral = _clientPeripheral;
    _clientPeripheral = null;
    _clientRxChar = null;
    if (peripheral != null) {
      try {
        await _central?.disconnect(peripheral);
      } catch (e) {
        Logger.log('BLE disconnect: $e');
      }
    }
    _discovered.clear();
    await stopHosting();
    _framer.reset();
  }

  Future<void> dispose() async {
    await reset();
    await _inputController.close();
    await _peerConnectedController.close();
    await _errorController.close();
    await _closedController.close();
  }

  /// Whether this platform has a BLE implementation registered (Android,
  /// iOS, macOS, Windows, Linux — not web/tests).
  static bool get isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS ||
      Platform.isWindows || Platform.isLinux;
}
