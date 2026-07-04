import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;

import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_peer.dart';

/// Android Bluetooth Classic (RFCOMM/SPP) engine.
///
/// Scanning and the client ("join") connection use the flutter_blue_classic
/// package directly — it covers those well. Hosting ("start session") uses a
/// small custom platform channel (see
/// android/.../bluetooth/BluetoothServerHandler.kt) because
/// flutter_blue_classic only exposes outgoing connect(), not
/// listenUsingRfcommWithServiceRecord()/accept() needed to host.
class ClassicBluetoothEngine {
  static const _serverMethods = MethodChannel('tark/bluetooth_server/methods');
  static const _serverConnectionEvents =
      EventChannel('tark/bluetooth_server/connection');
  static const _serverReadEvents = EventChannel('tark/bluetooth_server/read');

  /// On Android 6–11 classic discovery silently returns NOTHING unless the
  /// app holds fine location — [usesFineLocation] makes the plugin request
  /// it before scanning. Must stay false on Android 12+ (the permission
  /// isn't declared there; BLUETOOTH_SCAN with neverForLocation covers it).
  ClassicBluetoothEngine({bool usesFineLocation = false})
      : _fbc = fbc.FlutterBlueClassic(usesFineLocation: usesFineLocation);

  /// Android API level, fetched natively (no plugin dependency).
  static Future<int> sdkInt() async =>
      await _serverMethods.invokeMethod<int>('sdkInt') ?? 0;

  final fbc.FlutterBlueClassic _fbc;

  fbc.BluetoothConnection? _clientConnection;
  StreamSubscription<Uint8List>? _clientReadSub;

  StreamSubscription<dynamic>? _hostConnectionSub;
  StreamSubscription<dynamic>? _hostReadSub;
  bool _hosting = false;

  final _inputController = StreamController<Uint8List>.broadcast();
  final _peerConnectedController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _closedController = StreamController<void>.broadcast();

  /// Raw bytes received from the connected peer, regardless of role.
  Stream<Uint8List> get input => _inputController.stream;

  /// Fires with the peer's address once a connection is established.
  Stream<String> get onPeerConnected => _peerConnectedController.stream;

  Stream<String> get onError => _errorController.stream;

  Stream<void> get onClosed => _closedController.stream;

  Future<bool> get isSupported => _fbc.isSupported;
  Future<bool> get isEnabled => _fbc.isEnabled;
  Future<bool> requestEnable() => _fbc.turnOn();

  // ── Host ─────────────────────────────────────────────────────────────────

  Future<void> requestDiscoverable({int durationSeconds = 120}) async {
    try {
      await _serverMethods.invokeMethod<bool>(
        'requestDiscoverable',
        {'durationSeconds': durationSeconds},
      );
    } catch (e) {
      Logger.log('requestDiscoverable failed: $e');
    }
  }

  Future<void> startHosting({String name = 'tark'}) async {
    await _hostConnectionSub?.cancel();
    await _hostReadSub?.cancel();
    _hosting = true;

    _hostConnectionSub = _serverConnectionEvents
        .receiveBroadcastStream()
        .listen((event) {
      final map = Map<Object?, Object?>.from(event as Map);
      switch (map['event']) {
        case 'connected':
          _peerConnectedController.add((map['address'] as String?) ?? '');
        case 'closed':
          _closedController.add(null);
        case 'error':
          _errorController.add((map['message'] as String?) ?? 'unknown error');
      }
    }, onError: (Object e) => Logger.log('Bluetooth host connection error: $e'));

    _hostReadSub = _serverReadEvents.receiveBroadcastStream().listen(
      (event) => _inputController.add(event as Uint8List),
      onError: (Object e) => Logger.log('Bluetooth host read error: $e'),
    );

    try {
      await _serverMethods.invokeMethod<void>('startHosting', {'name': name});
    } catch (e) {
      _errorController.add('$e');
    }
  }

  Future<void> writeAsHost(Uint8List bytes) async {
    try {
      await _serverMethods.invokeMethod<void>('write', {'bytes': bytes});
    } catch (e) {
      Logger.log('Bluetooth host write failed: $e');
    }
  }

  Future<void> stopHosting() async {
    _hosting = false;
    await _hostConnectionSub?.cancel();
    _hostConnectionSub = null;
    await _hostReadSub?.cancel();
    _hostReadSub = null;
    try {
      await _serverMethods.invokeMethod<void>('stopHosting');
    } catch (e) {
      Logger.log('stopHosting failed: $e');
    }
  }

  // ── Join (client) ────────────────────────────────────────────────────────

  Stream<BluetoothPeer> scanForHosts() {
    _fbc.startScan();
    return _fbc.scanResults.map(
      (d) => BluetoothPeer(
        id: d.address,
        name: d.name ?? d.address,
        rssi: d.rssi,
      ),
    );
  }

  void cancelDiscovery() => _fbc.stopScan();

  Future<void> connectToHost(String address) async {
    cancelDiscovery();
    try {
      final connection = await _fbc.connect(address);
      if (connection == null) {
        _errorController.add('Failed to connect');
        return;
      }
      _clientConnection = connection;
      _peerConnectedController.add(address);
      _clientReadSub = connection.input?.listen(
        (data) => _inputController.add(data),
        onDone: () => _closedController.add(null),
        onError: (Object e) => _errorController.add('$e'),
      );
    } catch (e) {
      _errorController.add('$e');
    }
  }

  Future<void> writeAsClient(Uint8List bytes) async {
    _clientConnection?.output.add(bytes);
  }

  // ── Unified write (picks whichever role is active) ──────────────────────

  Future<void> write(Uint8List bytes) async {
    if (_clientConnection != null) {
      await writeAsClient(bytes);
    } else if (_hosting) {
      await writeAsHost(bytes);
    }
  }

  Future<void> reset() async {
    cancelDiscovery();
    await stopHosting();
    await _clientReadSub?.cancel();
    _clientReadSub = null;
    _clientConnection?.dispose();
    _clientConnection = null;
  }

  Future<void> dispose() async {
    await reset();
    await _inputController.close();
    await _peerConnectedController.close();
    await _errorController.close();
    await _closedController.close();
  }
}
