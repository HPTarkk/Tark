import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/utils/logger.dart';
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

  /// BLE/classic discovery failed before a trustworthy candidate was found.
  scanFailed,

  /// Native host readiness (identity/server/BLE advertising) failed.
  hostSetupFailed,

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

  static String rendezvousName(String token) => rendezvousHostName(token);

  void _wire() {
    if (_wired) return;
    _wired = true;
    _subscriptions
      ..add(
        _engine.input.listen((chunk) {
          try {
            for (final frame in _framer.addBytes(chunk)) {
              try {
                final decoded = utf8.decode(frame, allowMalformed: false);
                if (!_messages.isClosed) _messages.add(decoded);
              } catch (_) {
                // Malformed UTF-8 is untrusted input; drop this frame only.
              }
            }
          } on FormatException {
            // A hostile/garbled length prefix must not grow the buffer without
            // bound or poison the next control message.
            _framer.reset();
            Logger.diagnostic(
              'room_proximity: malformed control frame dropped',
            );
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
    _engine.setRendezvousToken(rendezvousToken);
    await _ensureAdapterOn();

    // Prepare identity, RFCOMM listener and BLE rendezvous advertising before
    // asking Android to expose the phone to classic inquiry. The QR must not
    // become usable while native hosting is only partially ready.
    try {
      await _engine.startHosting(
        name: encodeHostName(rendezvousName(rendezvousToken)),
      );
    } catch (error) {
      Logger.diagnostic('room_proximity: host readiness failed');
      await _engine.stopHosting();
      throw RoomProximityException(
        RoomProximityFailure.hostSetupFailed,
        'proximity host readiness failed: ${error.runtimeType}',
      );
    }

    final bool discoverable;
    try {
      discoverable = await _engine.requestDiscoverable();
    } catch (error) {
      Logger.diagnostic('room_proximity: discoverability setup failed');
      await _engine.stopHosting();
      throw RoomProximityException(
        RoomProximityFailure.hostSetupFailed,
        'Bluetooth discoverability setup failed: ${error.runtimeType}',
      );
    }
    if (!discoverable) {
      Logger.diagnostic('room_proximity: discoverability denied');
      await _engine.stopHosting();
      throw RoomProximityException(
        RoomProximityFailure.discoverabilityDenied,
        'Bluetooth discoverability was not granted',
      );
    }
    Logger.diagnostic('room_proximity: host ready');
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
    _engine.setRendezvousToken(rendezvousToken);
    Logger.diagnostic('room_proximity: connect start');
    await _ensureAdapterOn();

    final peerCompleter = Completer<BluetoothPeer>();
    StreamSubscription<BluetoothPeer>? scan;
    void startScan() {
      scan = _engine.scanForHosts().listen(
        (peer) {
          if (peerCompleter.isCompleted || !peer.isAppHost) return;
          // Room peer selection is cryptographically bound to the scanned
          // invitation's BLE service-data. A mutable/cached adapter name is
          // never sufficient evidence for production Room rendezvous.
          if (peer.rendezvousMatched) {
            peerCompleter.complete(peer);
          }
        },
        onError: (Object error) {
          if (!peerCompleter.isCompleted) {
            peerCompleter.completeError(
              RoomProximityException(
                RoomProximityFailure.scanFailed,
                'proximity scan failed: ${error.runtimeType}',
              ),
            );
          }
        },
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
        Logger.diagnostic('room_proximity: host lookup timed out');
        throw RoomProximityException(
          RoomProximityFailure.hostNotFound,
          'proximity host was not found',
        );
      }
      Logger.diagnostic('room_proximity: host found');
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
        // The native connectToPeer() call itself can block while Android is
        // opening RFCOMM. Put that call AND the connected event behind one
        // deadline; timing only outcome.future starts the clock too late and
        // leaves the scanner stuck on "joining" if invokeMethod never returns.
        await (() async {
          await _engine.connectToHost(peer.id);
          await outcome.future;
        })().timeout(dialTimeout);
        Logger.diagnostic('room_proximity: connected');
      } on TimeoutException {
        Logger.diagnostic('room_proximity: dial timed out');
        // Future.timeout cannot cancel the underlying platform call. reset()
        // closes the pending native BluetoothSocket, which unblocks connect()
        // and guarantees the next scan starts from a clean session.
        await _engine.reset();
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
    if (enabled) {
      Logger.diagnostic('room_proximity: adapter enabled');
      return;
    }
    Logger.diagnostic('room_proximity: adapter disabled');
    var turnedOn = false;
    try {
      turnedOn = await _engine.requestEnable();
    } catch (_) {}
    if (!turnedOn) {
      Logger.diagnostic('room_proximity: adapter enable denied');
      throw RoomProximityException(
        RoomProximityFailure.bluetoothOff,
        'Bluetooth is off',
      );
    }
    Logger.diagnostic('room_proximity: adapter enabled after request');
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
    _engine.setRendezvousToken(null);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _engine.dispose();
    await _messages.close();
    await _closed.close();
  }
}
