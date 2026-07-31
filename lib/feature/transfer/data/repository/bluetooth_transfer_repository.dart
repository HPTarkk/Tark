import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/error/failure.dart';
import '../../../../core/identity/device_identity.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/exponential_backoff.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/entity/bluetooth_connection_state.dart' as bt;
import '../../domain/entity/bluetooth_host_name.dart';
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
  BluetoothTransferRepository(this._settingsRepository, this._identity);

  final SettingsRepository _settingsRepository;
  final DeviceIdentity _identity;
  late final _codec = WakiPacketCodec(_identity.id);

  // Classic RFCOMM is a raw byte stream, so the repo reassembles frames for
  // it. The BLE engine frames internally and emits complete messages.
  final _classicFramer = FrameReassembler();

  final _packetController = StreamController<WakiPacket>.broadcast();
  final _connectionStateController =
      StreamController<bt.BluetoothConnectionState>.broadcast();
  final _bleAdvertisingController = StreamController<bool>.broadcast();

  ClassicBluetoothEngine? _classicEngine;
  BleBluetoothEngine? _bleEngine;

  /// How many engines existed the last time [_listenToEngines] ran, so a
  /// newly created one gets wired exactly once (see [_wireNewEngine]).
  int _wiredEngineCount = 0;

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
  bool _autoReconnectEnabled = true;

  /// Guards against a *phantom* hosted session: the RFCOMM accept() lands (so
  /// the host declares itself connected and walks into the channel) while the
  /// joiner never registers the same socket and keeps dialing. Nothing ever
  /// arrives on a link like that, and with the server socket already closed
  /// after the first accept, no later dial can get in either — the pair is
  /// stuck until the app restarts. A joined peer starts broadcasting presence
  /// every 2s as soon as it reaches the channel, so silence well past that
  /// means the session isn't real: drop it and let the normal closed → re-host
  /// recovery put a fresh listener up. The grace has to clear the joiner's
  /// whole entry sequence (connect flash → channel → audio start → first
  /// presence tick), hence seconds rather than milliseconds.
  Timer? _sessionWatchdog;
  static const _firstPacketGrace = Duration(seconds: 15);

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
      usesFineLocation = await AndroidSdk.version() < 31;
    } catch (e) {
      Logger.log('sdkInt lookup failed: $e');
    }
    final engine = _classicEngine ??= ClassicBluetoothEngine(
      usesFineLocation: usesFineLocation,
    );
    // Subscribe as soon as an engine exists, so no caller can reach it before
    // its events have somewhere to go — the engines publish on broadcast
    // streams, which silently discard whatever they emit while unlistened.
    _wireNewEngine();
    return engine;
  }

  BleBluetoothEngine get _requireBle {
    if (!_bleSupported) {
      throw UnsupportedError(
        'Bluetooth mode is not supported on this platform.',
      );
    }
    final engine = _bleEngine ??= BleBluetoothEngine();
    _wireNewEngine();
    return engine;
  }

  /// Re-runs [_listenToEngines] when an engine has appeared since the last
  /// wiring. Cheap and idempotent, and it makes "the engines are always
  /// listened to" true by construction rather than by every entry point
  /// remembering to do it.
  void _wireNewEngine() {
    if (_engineCount == _wiredEngineCount) return;
    _listenToEngines();
  }

  int get _engineCount =>
      (_classicEngine != null ? 1 : 0) + (_bleEngine != null ? 1 : 0);

  @override
  Stream<bt.BluetoothConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Stream<bool> get bleAdvertising => _bleAdvertisingController.stream;

  // ── BluetoothTransport ──────────────────────────────────────────────────

  @override
  Future<bool> get isAdapterReady async {
    if (_classicSupported) {
      try {
        return await (await _classicAsync()).isEnabled;
      } catch (e) {
        Logger.log('Bluetooth adapter state check failed: $e');
        return false;
      }
    }
    // iOS: there is no enable dialog to avoid — a powered-off adapter just
    // yields nothing and the attempt fizzles out quietly.
    return _bleSupported;
  }

  @override
  Future<void> startHosting() async {
    _sessionRole = 'host';
    _connectionStateController.add(bt.BluetoothConnectionState.hosting);

    // Advertise the user's display name so the joiner sees who they're
    // connecting to, not a generic hostname.
    final storedName = await _settingsRepository.getMyName();
    final deviceName = storedName.isEmpty ? 'Tark' : storedName;

    if (_classicSupported) {
      // Classic first: its discoverable dialog is also what prompts the
      // user to turn Bluetooth ON. BLE hosting follows in the background —
      // it only matters for iPhone joiners, and it must never delay or
      // fail the classic Android↔Android path (it waits internally for
      // the adapter the dialog just powered on).
      final classic = await _classicAsync();
      _requireBle;
      _listenToEngines();
      // Listening on RFCOMM does NOT make this device show up in anyone's
      // scan — only DISCOVERABLE scan mode does. Skipping this left a host
      // that looked live on its own screen completely invisible to a joiner
      // that was scanning rather than re-dialing a remembered address.
      // requestDiscoverable() returns immediately when a grant is still
      // running, so this costs a dialog only when it actually has to. It is
      // also awaited now: the same dialog is what powers the adapter on, and
      // listening before it was answered raced that.
      await classic.requestDiscoverable();
      // Classic broadcasts the TAGGED name: it renames the adapter, and the
      // tag is the only thing that marks this device as a Tark host in a
      // joiner's inquiry results. BLE needs no tag (joiners filter on the
      // service UUID) and its 31-byte advertisement has no room to spare.
      await classic.startHosting(name: encodeHostName(deviceName));
      unawaited(_bleEngine?.startHosting(name: deviceName) ?? Future.value());
    } else if (_bleSupported) {
      _requireBle;
      _listenToEngines();
      await _bleEngine!.startHosting(name: deviceName);
    }
  }

  @override
  Future<bool> get isHostDiscoverable async {
    if (!_classicSupported) return true;
    try {
      return await (await _classicAsync()).isDiscoverable;
    } catch (e) {
      Logger.log('Discoverability check failed: $e');
      return true; // Don't nag about something we couldn't measure.
    }
  }

  @override
  Future<bool> requestHostDiscoverable() async {
    if (!_classicSupported) return true;
    try {
      return await (await _classicAsync()).requestDiscoverable();
    } catch (e) {
      Logger.log('Discoverable request failed: $e');
      return false;
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
        _scanSubs.add(
          ble.scanForHosts().listen((peer) {
            if (!controller.isClosed) controller.add(peer);
          }, onError: (Object e) => Logger.log('BLE scan error: $e')),
        );
      }
      if (classic != null) {
        _scanSubs.add(
          classic.scanForHosts().listen((peer) {
            if (!controller.isClosed) controller.add(peer);
          }, onError: (Object e) => Logger.log('Classic scan error: $e')),
        );
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
      final ble = _requireBle;
      // Engine events have to be wired BEFORE the connect: the engines
      // announce a landed link on broadcast streams, which drop anything
      // emitted while nobody is listening.
      //
      // Hosting and scanning both did this; dialing did not — and a dial
      // that hasn't scanned first (the remembered-peer auto-join, and
      // "reconnect to last session") therefore connected for real while the
      // repository, and so the whole UI, never heard about it. The joiner sat
      // on "connecting" until its own 12s give-up reset the transport, which
      // closed the socket it had just opened, and the host — which HAD heard
      // its own accept — flapped connected/disconnected once per retry.
      _listenToEngines();
      await ble.connectToHost(peer.id.substring(4));
    } else {
      final classic = await _classicAsync();
      _listenToEngines();
      await classic.connectToHost(peer.id);
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
    _sessionWatchdog?.cancel();
    _sessionWatchdog = null;
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
    _wiredEngineCount = _engineCount;

    // Subscribes to whichever engines exist by now — callers create the
    // engines for their platform first, then call this.
    final ble = _bleEngine;
    if (ble != null) {
      _engineSubs
        ..add(ble.input.listen(_onMessage))
        ..add(ble.onPeerConnected.listen((id) => _onPeerConnected('ble', id)))
        ..add(ble.onError.listen((m) => _onEngineError('ble', m)))
        ..add(ble.onClosed.listen((_) => _onEngineClosed('ble')))
        ..add(
          ble.onAdvertising.listen((ok) {
            if (!_bleAdvertisingController.isClosed) {
              _bleAdvertisingController.add(ok);
            }
          }),
        );
    }
    final classic = _classicEngine;
    if (classic != null) {
      _engineSubs
        ..add(
          classic.input.listen((chunk) {
            for (final message in _classicFramer.addBytes(chunk)) {
              _onMessage(message);
            }
          }),
        )
        ..add(
          classic.onPeerConnected.listen(
            (address) => _onPeerConnected('classic', address),
          ),
        )
        ..add(classic.onError.listen((m) => _onEngineError('classic', m)))
        ..add(classic.onClosed.listen((_) => _onEngineClosed('classic')));
    }
  }

  void _onMessage(Uint8List message) {
    // Anything at all from the peer proves the link is real.
    _sessionWatchdog?.cancel();
    _sessionWatchdog = null;
    final peerId = _connectedPeerId;
    if (peerId == null) return;
    final packet = _codec.decode(message, peerId);
    if (packet != null) _packetController.add(packet);
  }

  void _onPeerConnected(String engine, String peerId) {
    _activeEngine = engine;
    _connectedPeerId = peerId;
    _armPhantomSessionWatchdog(engine);
    // One peer per session: once someone connected over one engine, stop
    // advertising on the other so a second device can't join mid-session
    // and interleave bytes.
    if (engine == 'ble') {
      unawaited(_classicEngine?.stopHosting());
    } else {
      unawaited(_bleEngine?.stopHosting());
    }
    // Remember the role this device played so the next launch resumes the
    // same part hands-free (host re-hosts, joiner re-dials). The joiner also
    // remembers its peer, for the address it re-dials and the "reconnect to
    // last session" quick action on the role screen.
    final role = _sessionRole;
    if (role != null) {
      unawaited(_settingsRepository.setLastBluetoothRole(role));
    }
    final peer = _sessionPeer;
    if (role == 'joiner' && peer != null) {
      unawaited(
        _settingsRepository.setLastBluetoothPeer(id: peer.id, name: peer.name),
      );
    }
    _connectionStateController.add(bt.BluetoothConnectionState.connected);
    unawaited(_sendHello());
  }

  /// One packet on the wire the moment the link forms. A real peer therefore
  /// proves itself within milliseconds instead of only when its channel screen
  /// finishes starting audio — which is what [_sessionWatchdog] waits for, and
  /// what separates a live session from a socket nobody is holding. Dropped
  /// harmlessly on arrival if the peer hasn't opened its channel yet.
  Future<void> _sendHello() async {
    final storedName = await _settingsRepository.getMyName();
    await sendPresence(storedName.isEmpty ? 'Tark' : storedName, false);
  }

  /// See [_sessionWatchdog]. Host role only: a joiner reaches "connected"
  /// through its own completed handshake, so it has no equivalent blind spot.
  void _armPhantomSessionWatchdog(String engine) {
    _sessionWatchdog?.cancel();
    _sessionWatchdog = null;
    if (_sessionRole != 'host' || engine != 'classic') return;
    _sessionWatchdog = Timer(_firstPacketGrace, () {
      _sessionWatchdog = null;
      if (_connectedPeerId == null) return;
      Logger.log(
        'Hosted session went silent before its first packet — dropping it',
      );
      unawaited(_classicEngine?.closeHostedConnection() ?? Future.value());
    });
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
    _sessionWatchdog?.cancel();
    _sessionWatchdog = null;
    final hadSession = _connectedPeerId != null;
    _connectedPeerId = null;
    _activeEngine = null;
    _classicFramer.reset();
    if (hadSession && _sessionRole != null && _autoReconnectEnabled) {
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
    // This loop drives the engines directly rather than through the methods
    // above, so it re-asserts the subscriptions itself. They are live by
    // construction here (nothing could have reported a drop otherwise), but
    // the one place that assumed that and skipped it is what stranded the
    // joiner — cheap enough not to depend on the reasoning.
    _listenToEngines();

    // Telegram-style backoff: 4s → 8s → 16s … 64s. A successful reconnect
    // stops the loop (via _connectedPeerId), and the next drop starts a fresh
    // ExponentialBackoff from 4s, so this never inherits a stale long delay.
    final backoff = ExponentialBackoff();
    while (_reconnectGen == gen && _connectedPeerId == null) {
      try {
        if (role == 'host') {
          final storedName = await _settingsRepository.getMyName();
          final deviceName = storedName.isEmpty ? 'Tark' : storedName;
          // No discoverable dialog here: the joiner reconnects by address,
          // which only needs the RFCOMM server / BLE advertising back up.
          if (_classicSupported) {
            await (await _classicAsync()).startHosting(
              name: encodeHostName(deviceName),
            );
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

      // Sliced sleep so reset() aborts promptly.
      final slices = backoff.next().inMilliseconds ~/ 250;
      for (
        var i = 0;
        i < slices && _reconnectGen == gen && _connectedPeerId == null;
        i++
      ) {
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
    List<double> samples,
    String senderName,
  ) async {
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
    String senderName,
    bool isTalking,
  ) async {
    try {
      if (_connectedPeerId == null) {
        return const Right(null); // not connected yet — nothing to send
      }
      final payload = _codec.encodePresence(
        senderName,
        isTalking,
        role: sessionRole,
      );
      await _write(payload);
      return const Right(null);
    } catch (error) {
      Logger.log(error);
      return const Left(DataTransferFailure());
    }
  }

  /// Straight off [_sessionRole] — the same string that decides who re-hosts
  /// and who re-dials after a drop, so the badge on the peer's screen can
  /// never disagree with what this device is actually doing.
  @override
  SessionRole get sessionRole => switch (_sessionRole) {
    'host' => SessionRole.host,
    'joiner' => SessionRole.joiner,
    _ => SessionRole.unknown,
  };

  @override
  Stream<ConnectionHealth> connect() => connectionState.map(
    (s) => switch (s) {
      bt.BluetoothConnectionState.connected => const ConnectionHealth.healthy(),
      bt.BluetoothConnectionState.reconnecting =>
        const ConnectionHealth.reconnecting(),
      _ => const ConnectionHealth.down(),
    },
  );

  @override
  void setAutoReconnectEnabled(bool enabled) {
    _autoReconnectEnabled = enabled;
    if (!enabled && _connectedPeerId == null && _sessionRole != null) {
      _reconnectGen++; // abort any in-flight auto-reconnect loop
      _connectionStateController.add(bt.BluetoothConnectionState.disconnected);
    }
  }

  @override
  void retryNow() {
    if (_connectedPeerId != null || _sessionRole == null) return;
    unawaited(_autoReconnect());
  }

  @override
  void resetCodecState() => _codec.resetDecoders();

  @override
  void stopConnection() => reset();

  @override
  @disposeMethod
  void dispose() {
    _reconnectGen++;
    _sessionWatchdog?.cancel();
    _sessionWatchdog = null;
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
