import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_blue_classic/flutter_blue_classic.dart' as fbc;

import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_host_name.dart';
import '../../domain/entity/bluetooth_peer.dart';

/// Android Bluetooth Classic (RFCOMM/SPP) engine.
///
/// Discovery uses the flutter_blue_classic package — it covers inquiry and
/// adapter state well. Both ends of the *connection* go through a custom
/// platform channel (see android/.../bluetooth/BluetoothServerHandler.kt):
/// hosting because the package exposes no
/// listenUsingRfcommWithServiceRecord()/accept(), and dialing because the
/// package's connect() uses a SECURE socket while our server socket is
/// insecure — a mismatch that let the host accept a link the joiner could
/// never finish authenticating (see connectToPeer in the handler). Sharing
/// the native session plumbing also means one code path for reads, bounded
/// writes and close events regardless of which side opened the link.
class ClassicBluetoothEngine {
  static const _serverMethods = MethodChannel('tark/bluetooth_server/methods');
  static const _serverConnectionEvents = EventChannel(
    'tark/bluetooth_server/connection',
  );
  static const _serverReadEvents = EventChannel('tark/bluetooth_server/read');

  /// On Android 6–11 classic discovery silently returns NOTHING unless the
  /// app holds fine location — [usesFineLocation] makes the plugin request
  /// it before scanning. Must stay false on Android 12+ (the permission
  /// isn't declared there; BLUETOOTH_SCAN with neverForLocation covers it).
  ClassicBluetoothEngine({bool usesFineLocation = false})
    : _fbc = fbc.FlutterBlueClassic(usesFineLocation: usesFineLocation);

  final fbc.FlutterBlueClassic _fbc;

  /// Guards against overlapping outgoing dials (see [connectToHost]).
  /// [_dialGen] separates a dial from the one that superseded it, so a late
  /// failure can't clear the newer dial's guard.
  bool _dialing = false;
  int _dialGen = 0;
  DateTime? _dialStartedAt;

  /// After this, an unanswered dial stops holding the guard shut — the next
  /// attempt cancels it natively first. Longer than the auto-join loop's own
  /// 12s give-up so that, in the normal case, its reset() gets there first.
  static const _dialStuckAfter = Duration(seconds: 20);

  StreamSubscription<dynamic>? _sessionEventSub;
  StreamSubscription<dynamic>? _sessionReadSub;

  /// True between the native "connected" and "closed" events, for either
  /// role. Writes and the dial guard key off this rather than a role flag —
  /// hosting and dialing land on the same native session.
  bool _connected = false;

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

  /// Whether this device currently answers other phones' inquiries. False
  /// while merely listening on RFCOMM — a server socket is not the same thing
  /// as being findable, and a scanning joiner sees only the latter.
  Future<bool> get isDiscoverable async {
    try {
      return await _serverMethods.invokeMethod<bool>('isDiscoverable') ?? false;
    } catch (e) {
      Logger.log('isDiscoverable failed: $e');
      return false;
    }
  }

  /// Asks the system to make this device findable, resolving with the user's
  /// answer (immediately true when a previous grant is still running).
  ///
  /// 300s is the longest window every OEM dialog honours — 120s ran out while
  /// the joiner was still walking through its own permission prompts.
  /// The timeout only guards against a dialog whose result never comes back
  /// (activity torn down mid-prompt); hosting must not hang on that.
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async {
    try {
      final granted = await _serverMethods
          .invokeMethod<bool>('requestDiscoverable', {
            'durationSeconds': durationSeconds,
          })
          .timeout(const Duration(seconds: 60), onTimeout: () => false);
      return granted ?? false;
    } catch (e) {
      Logger.log('requestDiscoverable failed: $e');
      return false;
    }
  }

  /// Subscribes to the native session channels. Idempotent, and shared by
  /// both roles — the events are about the one live socket, not about who
  /// opened it.
  void _listenToSession() {
    _sessionEventSub ??= _serverConnectionEvents.receiveBroadcastStream().listen(
      (event) {
        final map = Map<Object?, Object?>.from(event as Map);
        switch (map['event']) {
          case 'connected':
            _connected = true;
            _peerConnectedController.add((map['address'] as String?) ?? '');
          case 'closed':
            _connected = false;
            _closedController.add(null);
          case 'error':
            _errorController.add((map['message'] as String?) ?? 'unknown error');
        }
      },
      onError: (Object e) => Logger.log('Bluetooth session event error: $e'),
    );

    _sessionReadSub ??= _serverReadEvents.receiveBroadcastStream().listen(
      (event) => _inputController.add(event as Uint8List),
      onError: (Object e) => Logger.log('Bluetooth session read error: $e'),
    );
  }

  Future<void> _cancelSessionSubs() async {
    await _sessionEventSub?.cancel();
    _sessionEventSub = null;
    await _sessionReadSub?.cancel();
    _sessionReadSub = null;
  }

  Future<void> startHosting({String name = 'tark'}) async {
    _listenToSession();
    try {
      await _serverMethods.invokeMethod<void>('startHosting', {'name': name});
    } catch (e) {
      _errorController.add('$e');
    }
  }

  /// Hands bytes to the native writer thread, which owns the bounded queue
  /// and drops the newest packet when the link can't keep up.
  Future<void> _writeToSession(Uint8List bytes) async {
    try {
      await _serverMethods.invokeMethod<void>('write', {'bytes': bytes});
    } catch (e) {
      Logger.log('Bluetooth write failed: $e');
    }
  }

  /// Drops the peer socket (and cancels any dial in flight) while leaving the
  /// role intact, so the repository's normal closed → re-host / re-dial
  /// recovery can run.
  Future<void> closeHostedConnection() async {
    try {
      await _serverMethods.invokeMethod<void>('closeConnection');
    } catch (e) {
      Logger.log('closeConnection failed: $e');
    }
  }

  /// Tears the native session down whichever role owns it: the listener, an
  /// accepted socket, and any dial still in flight.
  Future<void> stopHosting() async {
    _connected = false;
    await _cancelSessionSubs();
    try {
      await _serverMethods.invokeMethod<void>('stopHosting');
    } catch (e) {
      Logger.log('stopHosting failed: $e');
    }
  }

  // ── Join (client) ────────────────────────────────────────────────────────

  Stream<BluetoothPeer> scanForHosts() {
    _fbc.startScan();
    return _fbc.scanResults.map((d) {
      // Everything within radio range lands here — headsets, TVs, laptops —
      // so the broadcast name is also the only signal for which of them is a
      // Tark host (an inquiry never reveals the RFCOMM service record).
      final advertised = d.name ?? '';
      return BluetoothPeer(
        id: d.address,
        // A device that broadcast no name stays nameless — the UI says
        // "unnamed device", which means something to a person. Its MAC does
        // not, and it used to sit in the list looking like a serial number.
        name: advertised.isEmpty ? '' : decodeHostName(advertised),
        rssi: d.rssi,
        isAppHost: isTarkHostName(advertised),
      );
    });
  }

  void cancelDiscovery() => _fbc.stopScan();

  /// Dials [address] over the native insecure RFCOMM path. Success is
  /// reported by the session's "connected" event, not by this future, so
  /// both roles reach [onPeerConnected] the same way.
  Future<void> connectToHost(String address) async {
    // The auto-join loop fire-and-forgets its dials and re-dials on a timer,
    // so without a guard a slow connect turns into several live RFCOMM
    // sockets against the same host. The host accepts exactly one and then
    // stops listening, which leaves it holding a session the joiner isn't
    // tracking while every later dial fails.
    if (_connected) {
      Logger.log('BT dial skipped: already connected');
      return;
    }
    if (_dialing) {
      final startedAt = _dialStartedAt;
      final age = startedAt == null
          ? Duration.zero
          : DateTime.now().difference(startedAt);
      if (age < _dialStuckAfter) {
        Logger.log('BT dial skipped: a dial to $address is still in flight');
        return;
      }
      // Cancel it natively first: the socket is what the connect() thread is
      // blocked on, and the native side refuses a second dial while one is
      // pending anyway.
      Logger.log('BT dial: cancelling one stuck for ${age.inSeconds}s');
      await closeHostedConnection();
    }
    final gen = ++_dialGen;
    _dialing = true;
    _dialStartedAt = DateTime.now();
    cancelDiscovery();
    _listenToSession();
    try {
      final landed =
          await _serverMethods.invokeMethod<bool>('connectToPeer', {
            'address': address,
          }) ??
          false;
      if (!landed) {
        // Cancelled mid-dial; the native side closed the socket, so nothing
        // is left holding the host's session open.
        Logger.log('BT dial to $address was cancelled before it landed');
        _errorController.add('Failed to connect');
      }
    } catch (e) {
      Logger.log('BT dial to $address failed: $e');
      _errorController.add('$e');
    } finally {
      if (gen == _dialGen) _dialing = false;
    }
  }

  // ── Write (same native session either way) ──────────────────────────────

  Future<void> write(Uint8List bytes) async {
    if (!_connected) return;
    await _writeToSession(bytes);
  }

  Future<void> reset() async {
    cancelDiscovery();
    // stopHosting() tears down the native session whichever role opened it —
    // accepted socket, in-flight dial and all.
    await stopHosting();
    // Any dial still in flight belongs to the session being torn down; the
    // generation bump keeps its late failure from clearing a newer guard.
    _dialGen++;
    _dialing = false;
  }

  Future<void> dispose() async {
    await reset();
    await _inputController.close();
    await _peerConnectedController.close();
    await _errorController.close();
    await _closedController.close();
  }
}
