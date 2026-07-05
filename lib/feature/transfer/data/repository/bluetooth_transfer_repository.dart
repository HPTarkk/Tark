import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/bluetooth_connection_state.dart' as bt;
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/repository/bluetooth_transport.dart';
import '../../domain/repository/transfer_repository.dart';
import '../bluetooth/ble_bluetooth_engine.dart';
import '../bluetooth/classic_bluetooth_engine.dart';
import '../bluetooth/length_prefixed_framer.dart';
import '../codec/waki_packet_codec.dart';

/// Bluetooth transport for 1-to-1 sessions, running two engines:
///
///  * [ClassicBluetoothEngine] (RFCOMM/SPP) — Android only. Highest
///    bandwidth and the engine that already worked Android↔Android.
///  * [BleBluetoothEngine] (GATT) — Android and iOS. Apple forbids Classic
///    Bluetooth for third-party apps, so BLE is what makes iPhone↔iPhone
///    and iPhone↔Android possible. Opus keeps the audio well inside BLE
///    bandwidth.
///
/// Hosting advertises on every engine the platform supports; whichever peer
/// connects first wins and the other engine's hosting is stopped. Scanning
/// merges both engines' results — BLE peer ids carry a `ble:` prefix so
/// connect() knows which engine owns the peer.
@lazySingleton
class BluetoothTransferRepository
    implements TransferRepository, BluetoothTransport {
  final _codec = WakiPacketCodec();

  // Classic RFCOMM is a raw byte stream, so the repo reassembles frames for
  // it. The BLE engine frames internally and emits complete messages.
  final _classicFramer = FrameReassembler();

  final _packetController = StreamController<WakiPacket>.broadcast();
  final _connectionStateController =
      StreamController<bt.BluetoothConnectionState>.broadcast();
  final _bleAdvertisingController = StreamController<bool>.broadcast();

  ClassicBluetoothEngine? _classicEngine;
  BleBluetoothEngine? _bleEngine;

  final List<StreamSubscription<dynamic>> _engineSubs = [];
  StreamController<BluetoothPeer>? _scanController;
  final List<StreamSubscription<BluetoothPeer>> _scanSubs = [];

  /// Which engine carries the active connection ('classic' | 'ble' | null).
  String? _activeEngine;
  String? _connectedPeerId;
  int _audioSeq = 0;

  // Auto-reconnect bookkeeping. A dropped session on a ride must heal by
  // itself: the host resumes listening/advertising (the joiner re-dials by
  // address, so no new discoverable dialog is needed), the joiner keeps
  // re-dialing the lost peer with backoff. reset() bumps the generation to
  // abort any loop still sleeping.
  String? _sessionRole; // 'host' | 'joiner'
  BluetoothPeer? _sessionPeer; // joiner's target
  int _reconnectGen = 0;
  static const _reconnectDelaysSeconds = [2, 3, 5, 8];

  bool get _classicSupported => Platform.isAndroid;
  bool get _bleSupported => Platform.isAndroid || Platform.isIOS;

  /// Creation is async because Android 6–11 needs the plugin to request
  /// fine location before classic discovery works (returns nothing without
  /// it), while on 12+ that permission isn't even declared — the API level
  /// decides, and it comes over a platform channel.
  Future<ClassicBluetoothEngine> _classicAsync() async {
    if (!_classicSupported) {
      throw UnsupportedError('Classic Bluetooth requires Android.');
    }
    final existing = _classicEngine;
    if (existing != null) return existing;
    var usesFineLocation = false;
    try {
      usesFineLocation = await ClassicBluetoothEngine.sdkInt() < 31;
    } catch (e) {
      Logger.log('sdkInt lookup failed: $e');
    }
    return _classicEngine ??=
        ClassicBluetoothEngine(usesFineLocation: usesFineLocation);
  }

  BleBluetoothEngine get _requireBle {
    if (!_bleSupported) {
      throw UnsupportedError('Bluetooth mode is not supported on this platform.');
    }
    final engine = _bleEngine ??= BleBluetoothEngine();
    return engine;
  }

  @override
  Stream<bt.BluetoothConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Stream<bool> get bleAdvertising => _bleAdvertisingController.stream;

  // ── BluetoothTransport ──────────────────────────────────────────────────

  @override
  Future<void> startHosting() async {
    _sessionRole = 'host';
    _connectionStateController.add(bt.BluetoothConnectionState.hosting);

    // Advertise the user's display name so the joiner sees who they're
    // connecting to, not a generic hostname.
    final prefs = await SharedPreferences.getInstance();
    final deviceName = prefs.getString('user_name') ?? 'Tark';

    if (_classicSupported) {
      // Classic first: its discoverable dialog is also what prompts the
      // user to turn Bluetooth ON. BLE hosting follows in the background —
      // it only matters for iPhone joiners, and it must never delay or
      // fail the classic Android↔Android path (it waits internally for
      // the adapter the dialog just powered on).
      final classic = await _classicAsync();
      _requireBle;
      _listenToEngines();
      await classic.requestDiscoverable();
      await classic.startHosting(name: deviceName);
      unawaited(_bleEngine?.startHosting(name: deviceName) ?? Future.value());
    } else if (_bleSupported) {
      _requireBle;
      _listenToEngines();
      await _bleEngine!.startHosting(name: deviceName);
    }
  }

  @override
  Stream<BluetoothPeer> scanForHosts() {
    _connectionStateController.add(bt.BluetoothConnectionState.scanning);

    _closeScan();
    final controller = StreamController<BluetoothPeer>.broadcast();
    _scanController = controller;

    // Async so the joiner can be prompted to turn Bluetooth ON before the
    // scans start — a scan on a powered-off adapter just finds nothing.
    () async {
      ClassicBluetoothEngine? classic;
      if (_classicSupported) {
        classic = await _classicAsync();
        try {
          if (!await classic.isEnabled) {
            await classic.requestEnable();
          }
        } catch (e) {
          Logger.log('Bluetooth enable request failed: $e');
        }
      }
      if (_bleSupported) _requireBle;
      _listenToEngines();
      if (controller.isClosed) return;

      final ble = _bleEngine;
      if (ble != null) {
        _scanSubs.add(ble.scanForHosts().listen(
              (peer) {
                if (!controller.isClosed) controller.add(peer);
              },
              onError: (Object e) => Logger.log('BLE scan error: $e'),
            ));
      }
      if (classic != null) {
        _scanSubs.add(classic.scanForHosts().listen(
              (peer) {
                if (!controller.isClosed) controller.add(peer);
              },
              onError: (Object e) => Logger.log('Classic scan error: $e'),
            ));
      }
    }();

    return controller.stream;
  }

  @override
  Future<void> connectToHost(BluetoothPeer peer) async {
    _sessionRole = 'joiner';
    _sessionPeer = peer;
    _connectionStateController.add(bt.BluetoothConnectionState.connecting);
    cancelDiscovery();
    if (peer.id.startsWith('ble:')) {
      await _requireBle.connectToHost(peer.id.substring(4));
    } else {
      await (await _classicAsync()).connectToHost(peer.id);
    }
  }

  @override
  void cancelDiscovery() {
    _closeScan();
    _bleEngine?.cancelDiscovery();
    _classicEngine?.cancelDiscovery();
  }

  void _closeScan() {
    for (final sub in _scanSubs) {
      sub.cancel();
    }
    _scanSubs.clear();
    _scanController?.close();
    _scanController = null;
  }

  @override
  void reset() {
    _reconnectGen++;
    _sessionRole = null;
    _sessionPeer = null;
    _connectedPeerId = null;
    _activeEngine = null;
    _classicFramer.reset();
    _closeScan();
    unawaited(_classicEngine?.reset());
    unawaited(_bleEngine?.reset());
    _connectionStateController.add(bt.BluetoothConnectionState.disconnected);
  }

  // ── Engine event plumbing ───────────────────────────────────────────────

  void _listenToEngines() {
    for (final sub in _engineSubs) {
      sub.cancel();
    }
    _engineSubs.clear();
    _classicFramer.reset();

    // Subscribes to whichever engines exist by now — callers create the
    // engines for their platform first, then call this.
    final ble = _bleEngine;
    if (ble != null) {
      _engineSubs
        ..add(ble.input.listen(_onMessage))
        ..add(ble.onPeerConnected.listen((id) => _onPeerConnected('ble', id)))
        ..add(ble.onError.listen((m) => _onEngineError('ble', m)))
        ..add(ble.onClosed.listen((_) => _onEngineClosed('ble')))
        ..add(ble.onAdvertising.listen((ok) {
          if (!_bleAdvertisingController.isClosed) {
            _bleAdvertisingController.add(ok);
          }
        }));
    }
    final classic = _classicEngine;
    if (classic != null) {
      _engineSubs
        ..add(classic.input.listen((chunk) {
          for (final message in _classicFramer.addBytes(chunk)) {
            _onMessage(message);
          }
        }))
        ..add(classic.onPeerConnected
            .listen((address) => _onPeerConnected('classic', address)))
        ..add(classic.onError.listen((m) => _onEngineError('classic', m)))
        ..add(classic.onClosed.listen((_) => _onEngineClosed('classic')));
    }
  }

  void _onMessage(Uint8List message) {
    final peerId = _connectedPeerId;
    if (peerId == null) return;
    final packet = _codec.decode(message, peerId);
    if (packet != null) _packetController.add(packet);
  }

  void _onPeerConnected(String engine, String peerId) {
    _activeEngine = engine;
    _connectedPeerId = peerId;
    // One peer per session: once someone connected over one engine, stop
    // advertising on the other so a second device can't join mid-session
    // and interleave bytes.
    if (engine == 'ble') {
      unawaited(_classicEngine?.stopHosting());
    } else {
      unawaited(_bleEngine?.stopHosting());
    }
    // Remember the joiner's peer for the "reconnect to last session" quick
    // action on the role screen.
    final peer = _sessionPeer;
    if (_sessionRole == 'joiner' && peer != null) {
      unawaited(SharedPreferences.getInstance().then((prefs) async {
        await prefs.setString('bt_last_peer_id', peer.id);
        await prefs.setString('bt_last_peer_name', peer.name);
      }));
    }
    _connectionStateController.add(bt.BluetoothConnectionState.connected);
  }

  void _onEngineError(String engine, String message) {
    Logger.log('Bluetooth $engine error: $message');
    // Never disturb an established session.
    if (_connectedPeerId != null) return;
    // On Android, Classic is the primary engine — a BLE hiccup (advertise
    // rejected, adapter still powering on, permission variance) must not
    // flip the whole flow into the error screen while Classic is fine.
    // BLE errors are only fatal where BLE is the ONLY engine (iOS).
    if (_classicSupported && engine == 'ble') return;
    _connectionStateController.add(bt.BluetoothConnectionState.error);
  }

  void _onEngineClosed(String engine) {
    if (_activeEngine != null && _activeEngine != engine) return;
    final hadSession = _connectedPeerId != null;
    _connectedPeerId = null;
    _activeEngine = null;
    _classicFramer.reset();
    if (hadSession && _sessionRole != null) {
      unawaited(_autoReconnect());
    } else {
      _connectionStateController.add(bt.BluetoothConnectionState.disconnected);
    }
  }

  /// Heals an unexpectedly dropped session without user interaction. Ends
  /// when the link is back or reset() is called (which bumps the
  /// generation and emits its own disconnected state).
  Future<void> _autoReconnect() async {
    final gen = ++_reconnectGen;
    final role = _sessionRole;
    _connectionStateController.add(bt.BluetoothConnectionState.reconnecting);
    Logger.log('Bluetooth session dropped — auto-reconnecting as $role');

    var attempt = 0;
    while (_reconnectGen == gen && _connectedPeerId == null) {
      try {
        if (role == 'host') {
          final prefs = await SharedPreferences.getInstance();
          final deviceName = prefs.getString('user_name') ?? 'Tark';
          // No discoverable dialog here: the joiner reconnects by address,
          // which only needs the RFCOMM server / BLE advertising back up.
          if (_classicSupported) {
            await (await _classicAsync()).startHosting(name: deviceName);
          }
          if (_bleSupported) {
            await _requireBle.startHosting(name: deviceName);
          }
        } else {
          final peer = _sessionPeer;
          if (peer == null) break;
          if (peer.isBle) {
            await _requireBle.connectToHost(peer.id.substring(4));
          } else {
            await (await _classicAsync()).connectToHost(peer.id);
          }
        }
      } catch (e) {
        Logger.log('Reconnect attempt failed: $e');
      }

      final delay = _reconnectDelaysSeconds[
          attempt < _reconnectDelaysSeconds.length
              ? attempt
              : _reconnectDelaysSeconds.length - 1];
      attempt++;
      // Sliced sleep so reset() aborts promptly.
      for (var i = 0;
          i < delay * 4 && _reconnectGen == gen && _connectedPeerId == null;
          i++) {
        await Future.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _write(Uint8List payload) async {
    switch (_activeEngine) {
      case 'ble':
        await _bleEngine?.write(payload);
      case 'classic':
        // Classic is a raw stream — frame here.
        await _classicEngine?.write(frameMessage(payload));
      default:
        // Not connected — drop.
        break;
    }
  }

  // ── TransferRepository ──────────────────────────────────────────────────

  @override
  Stream<WakiPacket> startListening() => _packetController.stream;

  @override
  Future<Either<Failure, void>> sendAudio(
      List<double> samples, String senderName) async {
    try {
      if (_connectedPeerId == null) {
        return const Left(DataTransferFailure());
      }
      final payload = _codec.encodeAudio(samples, senderName, _audioSeq++);
      await _write(payload);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Future<Either<Failure, void>> sendPresence(
      String senderName, bool isTalking) async {
    try {
      if (_connectedPeerId == null) {
        return const Right(null); // not connected yet — nothing to send
      }
      final payload = _codec.encodePresence(senderName, isTalking);
      await _write(payload);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  @override
  Stream<bool> connect() =>
      connectionState.map((s) => s == bt.BluetoothConnectionState.connected);

  @override
  void stopConnection() => reset();

  @override
  @disposeMethod
  void dispose() {
    _reconnectGen++;
    for (final sub in _engineSubs) {
      unawaited(sub.cancel());
    }
    _engineSubs.clear();
    _closeScan();
    unawaited(_classicEngine?.dispose());
    unawaited(_bleEngine?.dispose());
    unawaited(_packetController.close());
    unawaited(_connectionStateController.close());
    unawaited(_bleAdvertisingController.close());
    _codec.release();
  }
}
