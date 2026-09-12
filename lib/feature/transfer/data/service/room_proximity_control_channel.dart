import 'dart:async';
import 'dart:convert';

import '../../domain/entity/bluetooth_host_name.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../bluetooth/classic_bluetooth_engine.dart';
import '../bluetooth/length_prefixed_framer.dart';

/// A small, persistent RFCOMM control plane used before any high-bandwidth
/// Room transport is planned.
///
/// This deliberately reuses Tark's proven Android Bluetooth native bridge, but
/// owns a separate Dart lifecycle from the audio transport. The socket carries
/// only bounded UTF-8 control envelopes (membership request/grant/receipt now;
/// transport plan/credentials later). Wi-Fi is therefore never a prerequisite
/// for durable Room membership.
final class RoomProximityControlChannel {
  RoomProximityControlChannel({ClassicBluetoothEngine? engine})
    : _engine = engine ?? ClassicBluetoothEngine();

  static const _rendezvousPrefix = 'R-';

  final ClassicBluetoothEngine _engine;
  final FrameReassembler _framer = FrameReassembler();
  final StreamController<String> _messages = StreamController.broadcast();
  final StreamController<void> _closed = StreamController.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool _wired = false;
  bool _disposed = false;

  Stream<String> get messages => _messages.stream;
  Stream<void> get closed => _closed.stream;

  static String rendezvousName(String token) {
    final clean = token.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{8,64}$').hasMatch(clean)) {
      throw const FormatException('invalid proximity rendezvous token');
    }
    return '$_rendezvousPrefix${clean.substring(0, 8)}';
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    _subscriptions
      ..add(
        _engine.input.listen((chunk) {
          for (final frame in _framer.addBytes(chunk)) {
            try {
              final decoded = utf8.decode(frame, allowMalformed: false);
              if (!_messages.isClosed) _messages.add(decoded);
            } catch (_) {
              // A malformed control frame is untrusted input. Drop it without
              // poisoning the persistent socket or the next framed message.
            }
          }
        }),
      )
      ..add(
        _engine.onClosed.listen((_) {
          _framer.reset();
          if (!_closed.isClosed) _closed.add(null);
        }),
      );
  }

  /// Makes this phone discoverable under a short room-scoped rendezvous name
  /// and starts the existing RFCOMM listener. The QR contains the token, not a
  /// MAC address, SSID or password.
  Future<void> host({required String rendezvousToken}) async {
    if (_disposed) throw StateError('proximity control channel is disposed');
    _wire();
    await _engine.requestDiscoverable();
    await _engine.startHosting(
      name: encodeHostName(rendezvousName(rendezvousToken)),
    );
  }

  /// Resolves the QR rendezvous token through normal nearby discovery and
  /// dials exactly that Tark host. No user-selected Host/Join role is exposed.
  Future<void> connect({required String rendezvousToken}) async {
    if (_disposed) throw StateError('proximity control channel is disposed');
    _wire();
    final expectedName = rendezvousName(rendezvousToken);
    final peerCompleter = Completer<BluetoothPeer>();
    late final StreamSubscription<BluetoothPeer> scan;
    scan = _engine.scanForHosts().listen((peer) {
      if (peerCompleter.isCompleted || !peer.isAppHost) return;
      if (peer.name == expectedName) peerCompleter.complete(peer);
    });

    try {
      final peer = await peerCompleter.future;
      _engine.cancelDiscovery();
      final connected = _engine.onPeerConnected.first;
      await _engine.connectToHost(peer.id);
      await connected;
    } finally {
      _engine.cancelDiscovery();
      await scan.cancel();
    }
  }

  Future<void> send(String payload) async {
    if (_disposed) throw StateError('proximity control channel is disposed');
    final bytes = utf8.encode(payload);
    if (bytes.isEmpty || bytes.length > 16 * 1024) {
      throw const FormatException('invalid proximity control payload size');
    }
    await _engine.write(frameMessage(Uint8List.fromList(bytes)));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _engine.cancelDiscovery();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _engine.dispose();
    await _messages.close();
    await _closed.close();
  }
}
