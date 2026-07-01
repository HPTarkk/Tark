import 'dart:async';
import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/utils/logger.dart';
import '../../../walkie/domain/entity/waki_packet.dart';
import '../../domain/entity/bluetooth_connection_state.dart' as bt;
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/repository/bluetooth_transport.dart';
import '../../domain/repository/transfer_repository.dart';
import '../bluetooth/classic_bluetooth_engine.dart';
import '../bluetooth/length_prefixed_framer.dart';
import '../codec/waki_packet_codec.dart';

/// Bluetooth transport for 1-to-1 sessions.
///
/// Android uses [ClassicBluetoothEngine] (RFCOMM/SPP). iOS support (BLE via
/// Core Bluetooth) is deferred — Apple does not allow third-party apps to
/// use Classic Bluetooth at all, so iOS needs a structurally different
/// engine (central + peripheral roles) added in a later phase.
@lazySingleton
class BluetoothTransferRepository
    implements TransferRepository, BluetoothTransport {
  final _codec = const WakiPacketCodec();
  final _framer = FrameReassembler();
  final _packetController = StreamController<WakiPacket>.broadcast();
  final _connectionStateController =
      StreamController<bt.BluetoothConnectionState>.broadcast();

  ClassicBluetoothEngine? _classicEngine;
  StreamSubscription<dynamic>? _inputSub;
  StreamSubscription<String>? _peerConnectedSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<void>? _closedSub;

  String? _connectedPeerId;
  int _audioSeq = 0;

  ClassicBluetoothEngine get _requireClassicEngine {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
          'Bluetooth mode on this platform is not implemented yet.');
    }
    return _classicEngine ??= ClassicBluetoothEngine();
  }

  @override
  Stream<bt.BluetoothConnectionState> get connectionState =>
      _connectionStateController.stream;

  // ── BluetoothTransport ──────────────────────────────────────────────────

  @override
  Future<void> startHosting() async {
    final engine = _requireClassicEngine;
    _listenToEngine(engine);
    _connectionStateController.add(bt.BluetoothConnectionState.hosting);
    await engine.requestDiscoverable();
    await engine.startHosting();
  }

  @override
  Stream<BluetoothPeer> scanForHosts() {
    final engine = _requireClassicEngine;
    _listenToEngine(engine);
    _connectionStateController.add(bt.BluetoothConnectionState.scanning);
    return engine.scanForHosts();
  }

  @override
  Future<void> connectToHost(BluetoothPeer peer) async {
    final engine = _requireClassicEngine;
    _connectionStateController.add(bt.BluetoothConnectionState.connecting);
    await engine.connectToHost(peer.id);
  }

  @override
  void cancelDiscovery() => _classicEngine?.cancelDiscovery();

  @override
  void reset() {
    _connectedPeerId = null;
    _framer.reset();
    unawaited(_classicEngine?.reset());
    _connectionStateController.add(bt.BluetoothConnectionState.disconnected);
  }

  void _listenToEngine(ClassicBluetoothEngine engine) {
    _inputSub?.cancel();
    _peerConnectedSub?.cancel();
    _errorSub?.cancel();
    _closedSub?.cancel();

    _inputSub = engine.input.listen((chunk) {
      final messages = _framer.addBytes(chunk);
      for (final message in messages) {
        final peerId = _connectedPeerId;
        if (peerId == null) continue;
        final packet = _codec.decode(message, peerId);
        if (packet != null) _packetController.add(packet);
      }
    });

    _peerConnectedSub = engine.onPeerConnected.listen((address) {
      _connectedPeerId = address;
      _connectionStateController.add(bt.BluetoothConnectionState.connected);
    });

    _errorSub = engine.onError.listen((message) {
      Logger.log('Bluetooth error: $message');
      _connectionStateController.add(bt.BluetoothConnectionState.error);
    });

    _closedSub = engine.onClosed.listen((_) {
      _connectedPeerId = null;
      _connectionStateController.add(bt.BluetoothConnectionState.disconnected);
    });
  }

  // ── TransferRepository ──────────────────────────────────────────────────

  @override
  Stream<WakiPacket> startListening() => _packetController.stream;

  @override
  Future<Either<Failure, void>> sendAudio(
      List<double> samples, String senderName) async {
    try {
      final engine = _classicEngine;
      if (engine == null || _connectedPeerId == null) {
        return const Left(DataTransferFailure());
      }
      final payload = _codec.encodeAudio(samples, senderName, _audioSeq++);
      await engine.write(frameMessage(payload));
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
      final engine = _classicEngine;
      if (engine == null || _connectedPeerId == null) {
        return const Right(null); // not connected yet — nothing to send
      }
      final payload = _codec.encodePresence(senderName, isTalking);
      await engine.write(frameMessage(payload));
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
    unawaited(_inputSub?.cancel());
    unawaited(_peerConnectedSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_closedSub?.cancel());
    unawaited(_classicEngine?.dispose());
    unawaited(_packetController.close());
    unawaited(_connectionStateController.close());
  }
}
