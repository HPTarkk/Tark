import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entity/bluetooth_host_name.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../bluetooth/classic_bluetooth_engine.dart';
import '../bluetooth/length_prefixed_framer.dart';

/// Why a proximity rendezvous could not be completed.
///
/// Callers turn these into something the person holding the phone can act
/// on: a switch to flip, a phone to stand closer to, or a fresh invite.
enum RoomProximityFailure {
  /// The host declined Android's "make this phone visible" prompt.
  discoverabilityDenied,

  /// This phone's Bluetooth is off and was not switched on.
  bluetoothOff,

  /// No phone advertising this invite turned up before the find timeout.
  hostNotFound,

  /// The host was found but the RFCOMM dial did not land.
  dialFailed,
}

/// A [StateError], so callers that only care that the rendezvous failed keep
/// working, carrying [failure] for the ones that want to say why.
final class RoomProximityException extends StateError {
  RoomProximityException(this.failure, super.message);

  final RoomProximityFailure failure;
}

/// A small, persistent RFCOMM control plane used before any high-bandwidth
/// Room transport is planned.
///
/// This deliberately reuses Tark's proven Android Bluetooth native bridge, but
/// owns a separate Dart lifecycle from the audio transport. The socket carries
/// only bounded UTF-8 control envelopes (membership request/grant/receipt now;
/// transport plan/credentials later). Wi-Fi is therefore never a prerequisite
/// for durable Room membership.
final class RoomProximityControlChannel {
  RoomProximityControlChannel({
    ClassicBluetoothEngine? engine,
    this.findTimeout = const Duration(seconds: 30),
    this.dialTimeout = const Duration(seconds: 20),
    this.rescanEvery = const Duration(seconds: 12),
  }) : _engine = engine ?? ClassicBluetoothEngine();

  static const _rendezvousPrefix = 'R-';

  /// How long [connect] looks for the host before giving up.
  final Duration findTimeout;

  /// How long a host that was found gets to accept the RFCOMM dial.
  final Duration dialTimeout;

  /// Android's classic inquiry runs for about 12s and then stops on its own —
  /// without closing the result stream, so nothing downstream learns the scan
  /// is over. [connect] restarts it on this cadence.
  final Duration rescanEvery;

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

  Future<void> host({required String rendezvousToken}) async {
    if (_disposed) throw StateError('proximity control channel is disposed');
    _wire();
    final discoverable = await _engine.requestDiscoverable();
    if (!discoverable) {
      throw RoomProximityException(
        RoomProximityFailure.discoverabilityDenied,
        'Bluetooth discoverability was not granted',
      );
    }
    await _engine.startHosting(
      name: encodeHostName(rendezvousName(rendezvousToken)),
    );
  }

  /// Finds the phone advertising [rendezvousToken] and dials it.
  ///
  /// Both halves are bounded. Before they were, a joiner that missed the
  /// host's inquiry window — or whose host had stopped being visible — sat on
  /// "joining" forever, and the scanner ignored every further scan because a
  /// join was still in flight.
  Future<void> connect({required String rendezvousToken}) async {
    if (_disposed) throw StateError('proximity control channel is disposed');
    _wire();
    final expectedName = rendezvousName(rendezvousToken);
    await _ensureAdapterOn();

    final peerCompleter = Completer<BluetoothPeer>();
    StreamSubscription<BluetoothPeer>? scan;
    void startScan() {
      scan = _engine.scanForHosts().listen(
        (peer) {
          if (peerCompleter.isCompleted || !peer.isAppHost) return;
          if (peer.name == expectedName) peerCompleter.complete(peer);
        },
        // A scan error is not a verdict: the rescan below and the find
        // timeout decide when to give up.
        onError: (Object _) {},
      );
    }

    Future<void> restartScan() async {
      // Cancel before listening again: the result stream is a platform event
      // channel, and a late cancel would tear down the new listener's sink.
      await scan?.cancel();
      if (peerCompleter.isCompleted || _disposed) return;
      _engine.cancelDiscovery();
      startScan();
    }

    startScan();
    final rescan = Timer.periodic(rescanEvery, (_) => unawaited(restartScan()));

    try {
      final BluetoothPeer peer;
      try {
        peer = await peerCompleter.future.timeout(findTimeout);
      } on TimeoutException {
        throw RoomProximityException(
          RoomProximityFailure.hostNotFound,
          'proximity host was not found',
        );
      }
      rescan.cancel();
      _engine.cancelDiscovery();

      final outcome = Completer<void>();
      final connectedSub = _engine.onPeerConnected.listen((_) {
        if (!outcome.isCompleted) outcome.complete();
      });
      final errorSub = _engine.onError.listen((message) {
        if (!outcome.isCompleted) {
          outcome.completeError(
            RoomProximityException(
              RoomProximityFailure.dialFailed,
              'proximity Bluetooth dial failed: $message',
            ),
          );
        }
      });
      final closedSub = _engine.onClosed.listen((_) {
        if (!outcome.isCompleted) {
          outcome.completeError(
            RoomProximityException(
              RoomProximityFailure.dialFailed,
              'proximity Bluetooth session closed before connect',
            ),
          );
        }
      });

      try {
        await _engine.connectToHost(peer.id);
        await outcome.future.timeout(dialTimeout);
      } on TimeoutException {
        throw RoomProximityException(
          RoomProximityFailure.dialFailed,
          'proximity Bluetooth dial timed out',
        );
      } finally {
        await connectedSub.cancel();
        await errorSub.cancel();
        await closedSub.cancel();
      }
    } finally {
      rescan.cancel();
      _engine.cancelDiscovery();
      await scan?.cancel();
    }
  }

  /// A joiner whose Bluetooth is switched off would otherwise scan in silence
  /// until the timeout. Ask once, up front. An adapter whose state cannot be
  /// read at all gets the benefit of the doubt — the find timeout still bounds
  /// the attempt.
  Future<void> _ensureAdapterOn() async {
    final bool enabled;
    try {
      enabled = await _engine.isEnabled;
    } catch (_) {
      return;
    }
    if (enabled) return;
    var turnedOn = false;
    try {
      turnedOn = await _engine.requestEnable();
    } catch (_) {}
    if (!turnedOn) {
      throw RoomProximityException(
        RoomProximityFailure.bluetoothOff,
        'Bluetooth is off',
      );
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
