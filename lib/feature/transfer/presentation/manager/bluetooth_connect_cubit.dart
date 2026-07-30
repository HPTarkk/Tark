import 'dart:async';
import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_player.dart';
import '../../../../core/utils/android_sdk.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../../domain/repository/bluetooth_transport.dart';
import '../../domain/service/bluetooth_host_faces.dart';
import '../../domain/service/bluetooth_host_filter.dart';

@injectable
class BluetoothConnectCubit extends Cubit<BluetoothConnectState> {
  final BluetoothTransport _transport;
  final SettingsRepository _settingsRepository;
  final SfxPlayer _sfx;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<BluetoothPeer>? _scanSub;
  StreamSubscription<bool>? _bleAdvertisingSub;
  Timer? _reconnectTimeout;

  /// Polls whether this device is still answering inquiries while hosting
  /// (see [_watchDiscoverability]).
  Timer? _discoverableTimer;

  /// Pending hands-free join of the only Tark host in range (see
  /// [_considerSoloAutoJoin]).
  Timer? _soloJoinTimer;

  /// How long the scan is given to turn up a SECOND Tark host before the
  /// first one is joined automatically. Short enough to feel instant, long
  /// enough that two friends hosting at once still get a choice.
  static const _soloJoinSettle = Duration(seconds: 2);

  /// True while a background auto-reconnect (started by the cubit itself,
  /// not a user tap) is in flight — its failures must fall back to role
  /// selection quietly instead of surfacing the error screen.
  bool _autoAttempt = false;

  /// True while the hands-free "keep dialing the remembered host until it
  /// answers" loop is running. Distinct from [_autoAttempt] because the loop
  /// owns error recovery itself: a failed dial must NOT drop to role
  /// selection (that's what left a first-launched joiner stranded when the
  /// host wasn't up yet) — it just waits and re-dials.
  bool _autoJoining = false;

  /// Bumped to cancel the auto-join loop (user backs out, a connection lands,
  /// or the cubit closes).
  int _autoJoinGen = 0;

  /// Completes as soon as the current dial resolves (connected or errored) so
  /// the loop can react immediately instead of waiting out its whole timeout.
  Completer<void>? _attemptSignal;

  BluetoothConnectCubit(this._transport, this._settingsRepository, this._sfx)
    : super(BluetoothConnectState.initial()) {
    _connectionSub = _transport.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) {
        _autoAttempt = false;
        _stopAutoJoin();
      } else if (s == BluetoothConnectionState.error) {
        // Wake the loop so it re-dials right away, and swallow the error:
        // while auto-joining the UI must stay on the "connecting" radar, not
        // flip to the error card.
        _signalAttempt();
        if (_autoJoining) return;
        if (_autoAttempt) {
          // A non-looping background attempt (auto-host, or a hung dial that
          // the loop already abandoned) failed — no error chirp/screen, just
          // the role selection the user would have seen otherwise.
          backToRoleSelection();
          return;
        }
      }
      // Clear the "connecting to this peer" marker once the attempt
      // resolves either way, so a failed connection can be retried — but keep
      // it pinned while the auto-join loop is mid-retry so the radar keeps
      // naming the host instead of flickering back to a bare "scanning".
      final stillConnecting = s == BluetoothConnectionState.connecting;
      switch (s) {
        case BluetoothConnectionState.connected:
          _sfx.play(SfxEvent.peerJoin);
        case BluetoothConnectionState.reconnecting:
          _sfx.play(SfxEvent.linkLost);
        case BluetoothConnectionState.error:
          _sfx.play(SfxEvent.error);
        default:
          break;
      }
      emit(
        state.copyWith(
          connectionState: s,
          connectingPeerId: (stillConnecting || _autoJoining)
              ? state.connectingPeerId
              : null,
        ),
      );
    }, onError: (Object e) => Logger.log('BT connection state error: $e'));
    // When BLE host advertising can't start, iPhones can't discover us — flag
    // it so the host screen can steer the user to the Wi-Fi hotspot bridge.
    _bleAdvertisingSub = _transport.bleAdvertising.listen((ok) {
      if (!ok && !isClosed) {
        emit(state.copyWith(bleUnavailable: true));
        _sfx.play(SfxEvent.error);
      }
    }, onError: (Object e) => Logger.log('BLE advertising state error: $e'));
    _loadIdentity().then((_) => _maybeAutoReconnect());
  }

  Future<void> _loadIdentity() async {
    final myName = await _settingsRepository.getMyName();
    final lastId = await _settingsRepository.getLastBluetoothPeerId();
    final lastName = await _settingsRepository.getLastBluetoothPeerName();
    if (isClosed) return;
    emit(
      state.copyWith(
        myName: myName.isEmpty ? 'Tark' : myName,
        lastPeer: lastId != null
            // A remembered peer is one we've already had a session with, so
            // it's an app host by definition — even before this scan proves
            // it again by name.
            ? BluetoothPeer(
                id: lastId,
                // Nameless rather than an address: the quick-reconnect card
                // says "unnamed device" instead of showing a MAC.
                name: lastName ?? '',
                isAppHost: true,
              )
            : null,
      ),
    );
  }

  /// Subsequent-connection fast path: once a session has connected, this
  /// device resumes the SAME role hands-free on the next visit to this screen
  /// — a host silently re-hosts, a joiner keeps dialing the remembered host
  /// until it answers. Only runs when the permissions are already granted and
  /// the adapter is already on, and the Auto-reconnect setting allows it — the
  /// one prompt it can still raise is the host's discoverable dialog, and only
  /// when the device genuinely isn't findable (see [_autoHost]).
  /// First-time use (no remembered role yet) keeps the explicit host/join
  /// confirmation flow.
  Future<void> _maybeAutoReconnect() async {
    if (isClosed || state.role != null) return;
    if (!await _settingsRepository.getAutoReconnectEnabled()) return;
    // Role first: what this device is about to do decides which permissions
    // have to already be in hand for it to do it silently.
    final lastRole = await _settingsRepository.getLastBluetoothRole();
    if (lastRole != 'host' && lastRole != 'joiner') return;
    if (!await _hasSilentPermissions(forHosting: lastRole == 'host')) return;
    if (!await _transport.isAdapterReady) return;
    // The user may have picked a role while the checks above were awaited.
    if (isClosed || state.role != null) return;
    if (lastRole == 'host') {
      await _autoHost();
    } else if (state.lastPeer != null) {
      await _autoJoin();
    }
    // Unknown role / nothing remembered → leave the role-selection screen up.
  }

  /// Hands-free host: resume the beacon without the user picking a role again.
  ///
  /// This used to skip the discoverable dialog entirely, on the theory that
  /// the remembered joiner re-dials by address. It does — but only while it
  /// still has that address and its own auto-join runs; the moment the other
  /// side scans instead (first pairing of the day after a "Cancel", swapped
  /// roles, auto-reconnect off, permissions re-prompted) it looked for a
  /// device that was answering nobody's inquiries, and found nothing. The
  /// dialog is skipped only when discoverability is genuinely already on,
  /// which the platform side checks before it shows anything, so a resumed
  /// host that IS still findable stays as silent as before. A start-up
  /// failure drops back to role selection so the user can host/join manually.
  Future<void> _autoHost() async {
    _autoAttempt = true;
    emit(state.copyWith(role: BluetoothRole.host, peers: const []));
    try {
      await _transport.startHosting();
      _watchDiscoverability();
    } catch (e) {
      Logger.log('Background auto-host failed to start: $e');
      if (!isClosed && _autoAttempt) backToRoleSelection();
    }
  }

  /// Android discoverability is a time-limited grant, so a host left waiting
  /// long enough goes invisible again with nothing on screen saying so. Poll
  /// while the beacon is up and unconnected, and let the UI offer a re-arm
  /// (rather than popping a dialog at a user who may have walked away).
  void _watchDiscoverability() {
    _discoverableTimer?.cancel();
    // Hosting can finish starting after the user has already backed out (the
    // discoverable dialog is awaited) — don't leave a timer polling for a
    // beacon that isn't on screen any more.
    if (isClosed || state.role != BluetoothRole.host) return;
    unawaited(_refreshDiscoverable());
    _discoverableTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_refreshDiscoverable()),
    );
  }

  Future<void> _refreshDiscoverable() async {
    if (isClosed) return;
    if (state.role != BluetoothRole.host ||
        state.connectionState == BluetoothConnectionState.connected) {
      _discoverableTimer?.cancel();
      return;
    }
    final discoverable = await _transport.isHostDiscoverable;
    if (isClosed || state.role != BluetoothRole.host) return;
    if (discoverable != state.hostDiscoverable) {
      emit(state.copyWith(hostDiscoverable: discoverable));
    }
  }

  /// "Let them find me" from the host screen, once the window has lapsed.
  Future<void> makeDiscoverable() async {
    final granted = await _transport.requestHostDiscoverable();
    if (isClosed) return;
    emit(state.copyWith(hostDiscoverable: granted));
  }

  /// Hands-free joiner: keep (re)dialing the remembered host until it answers
  /// or the user backs out. This is what makes cold-start rendezvous work
  /// regardless of which device launches first — a dial that fails because
  /// the host isn't up yet simply waits and tries again instead of stranding
  /// the joiner on the role screen.
  Future<void> _autoJoin() async {
    final peer = state.lastPeer;
    if (peer == null) return;
    _autoAttempt = true;
    _autoJoining = true;
    final gen = ++_autoJoinGen;
    emit(
      state.copyWith(
        role: BluetoothRole.joiner,
        peers: peer.isBle ? const [] : [peer],
        connectingPeerId: peer.id,
      ),
    );

    var attempt = 0;
    while (!isClosed && _autoJoining && _autoJoinGen == gen) {
      if (state.connectionState == BluetoothConnectionState.connected) break;
      emit(state.copyWith(connectingPeerId: peer.id));

      if (peer.isBle) {
        // BLE hosts must be rediscovered by UUID each time; the targeted scan
        // auto-connects the moment the remembered peer reappears.
        if (_scanSub == null) await _listenToScan(autoConnectId: peer.id);
      } else {
        // Classic: dial the address cold. Succeeds once the host's RFCOMM
        // server is listening; fails fast (and we retry) until then.
        // Fire-and-forget: a hung _fbc.connect must not block the loop, so the
        // signal (connected/error) or the timeout below bounds the attempt
        // instead of awaiting the dial directly.
        _attemptSignal = Completer<void>();
        unawaited(
          _transport.connectToHost(peer).catchError((Object e) {
            Logger.log('Auto-join dial failed: $e');
            _signalAttempt();
          }),
        );
      }

      final resolved = await _awaitAttempt(const Duration(seconds: 12), gen);
      if (isClosed || !_autoJoining || _autoJoinGen != gen) return;
      if (state.connectionState == BluetoothConnectionState.connected) break;
      // A dial that neither connected nor errored is hung — tear it down so
      // the next attempt starts clean.
      if (!resolved) _transport.reset();

      attempt++;
      await _sleep(Duration(seconds: (1 + attempt).clamp(2, 6)), gen);
    }
    if (_autoJoinGen == gen) _autoJoining = false;
  }

  /// Waits for the current dial to resolve (via [_attemptSignal]) or the
  /// timeout to elapse. Returns true if it resolved, false if it timed out
  /// (a hung dial). Cancels early if the loop generation moved on.
  Future<bool> _awaitAttempt(Duration timeout, int gen) async {
    final signal = _attemptSignal;
    if (signal == null) {
      // BLE path (no per-dial completer): poll for a landed connection.
      final slices = timeout.inMilliseconds ~/ 250;
      for (var i = 0; i < slices; i++) {
        if (isClosed || _autoJoinGen != gen) return true;
        if (state.connectionState == BluetoothConnectionState.connected) {
          return true;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    }
    try {
      await signal.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } finally {
      if (identical(_attemptSignal, signal)) _attemptSignal = null;
    }
  }

  /// Sliced delay that aborts promptly when the loop is cancelled.
  Future<void> _sleep(Duration total, int gen) async {
    final slices = total.inMilliseconds ~/ 200;
    for (var i = 0; i < slices; i++) {
      if (isClosed || !_autoJoining || _autoJoinGen != gen) return;
      if (state.connectionState == BluetoothConnectionState.connected) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _signalAttempt() {
    final signal = _attemptSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  void _stopAutoJoin() {
    _autoJoining = false;
    _autoJoinGen++;
    _signalAttempt();
    _attemptSignal = null;
  }

  /// Whether connecting can start without any permission dialog. Android:
  /// reading statuses never prompts, so require them already granted. iOS
  /// only ever shows the CoreBluetooth prompt once — a remembered peer means
  /// it was already answered, so there is nothing left to prompt for (a
  /// revocation just surfaces as a connection error, which the auto path
  /// swallows).
  Future<bool> _hasSilentPermissions({required bool forHosting}) async {
    if (Platform.isIOS) return true;
    if (!Platform.isAndroid) return false;
    // Assumes modern Android when the lookup fails — pre-S is the special
    // case, so defaulting to S+ keeps the long-standing behaviour.
    var preAndroidS = false;
    try {
      preAndroidS = await AndroidSdk.version() < 31;
    } catch (e) {
      Logger.log('SDK lookup failed, assuming Android S+: $e');
    }
    final statuses = await Future.wait([
      Permission.bluetoothScan.status,
      Permission.bluetoothConnect.status,
      // Hosting also advertises over BLE, which is a SEPARATE Android runtime
      // permission — and the manual flow has always requested all three.
      // Leaving it out here let the silent path judge itself permitted and
      // then bring up a half-deaf host: classic RFCOMM listened fine while
      // BLE advertising was rejected, and that rejection is deliberately
      // swallowed whenever classic is available (see the repository's
      // engine-error handling). A joiner whose remembered peer is a BLE one
      // then scanned for a service UUID nobody was broadcasting and sat on
      // "connecting" indefinitely — with no prompt, because the whole point
      // of this path is not to show one. Failing the check instead drops to
      // role selection, where tapping Host requests the permission properly.
      if (forHosting) Permission.bluetoothAdvertise.status,
      // Pre-S has no granular Bluetooth permissions, so every status above
      // reports granted whether or not the app can actually scan or
      // advertise — location is what gates both there. Without this the
      // silent path judges itself permitted, and the BLE stack then raises
      // its own location prompt mid-connect: exactly the unowned dialog that
      // collides with the walkie session's microphone request. Failing the
      // check instead drops to role selection, where tapping Host asks for
      // location properly and up front (see BluetoothConnectPage).
      if (preAndroidS) Permission.locationWhenInUse.status,
    ]);
    return statuses.every((s) => s.isGranted);
  }

  Future<void> startHosting() async {
    _autoAttempt = false;
    _stopAutoJoin();
    emit(
      state.copyWith(
        role: BluetoothRole.host,
        peers: const [],
        hostDiscoverable: true,
      ),
    );
    // Show the discoverable dialog if needed, so a fresh scan can find this
    // device (a brand-new joiner has no address to dial cold).
    try {
      await _transport.startHosting();
      _watchDiscoverability();
    } catch (e) {
      // The tap isn't awaited by the caller, so an escaping failure would
      // surface as an unhandled async error and leave the beacon pulsing over
      // a host that never started.
      Logger.log('Hosting failed to start: $e');
      if (!isClosed) backToRoleSelection();
    }
  }

  Future<void> startScanning() async {
    _autoAttempt = false;
    _stopAutoJoin();
    emit(state.copyWith(role: BluetoothRole.joiner, peers: const []));
    await _listenToScan();
  }

  Future<void> _listenToScan({String? autoConnectId}) async {
    await _scanSub?.cancel();
    late final StreamSubscription<BluetoothPeer> sub;
    sub = _transport.scanForHosts().listen(
      (peer) {
        // Only Tark hosts reach the list — everything else a classic inquiry
        // sweeps up is somebody's headset or TV, and unjoinable (see
        // [isVisibleHost] for the reconnect-target exception).
        if (!isVisibleHost(peer, reconnectTargetId: autoConnectId)) return;
        // Upsert: repeat discoveries refresh the RSSI, so the signal bars
        // (and the radar blip distance) stay live while scanning.
        final peers = [...state.peers];
        final idx = peers.indexWhere((p) => p.id == peer.id);
        if (idx >= 0) {
          peers[idx] = peer;
        } else {
          peers.add(peer);
        }
        // One entry per phone: an Android host answers on both radios, and the
        // duplicate read as two people — which also blocked the hands-free solo
        // join, since that refuses to guess between two hosts.
        final deduped = mergeHostFaces(peers);
        // Tark hosts first — everything here is one, bar the reconnect target
        // let through above — then strongest signal.
        deduped.sort((a, b) {
          if (a.isAppHost != b.isAppHost) return a.isAppHost ? -1 : 1;
          return (b.rssi ?? -999).compareTo(a.rssi ?? -999);
        });
        emit(state.copyWith(peers: deduped));

        if (autoConnectId != null) {
          if (peer.id == autoConnectId &&
              state.connectingPeerId == autoConnectId &&
              state.connectionState != BluetoothConnectionState.connecting) {
            // Internal variant: this dial belongs to whichever flow armed the
            // targeted scan, so it must not clear the auto-attempt marker.
            _connectTo(peer);
          }
        } else {
          _considerSoloAutoJoin();
        }
      },
      onError: (Object e) => Logger.log('BT scan error: $e'),
      onDone: () {
        // The repository closes the scan stream whenever it resets — which the
        // auto-join loop does itself on a hung dial. Without this, [_scanSub]
        // stayed non-null while pointing at a dead stream, and the loop's
        // "is a scan already running?" guard below then skipped re-arming it
        // forever: the joiner sat on the radar, never scanning again, and
        // could never rediscover the BLE host it was trying to reach.
        if (identical(_scanSub, sub)) _scanSub = null;
      },
    );
    _scanSub = sub;
  }

  /// Joins hands-free when the scan finds exactly one Tark host: with a
  /// single obvious peer, tapping it is pure ceremony. Still keyed on
  /// [BluetoothPeer.isAppHost] rather than the list length, since a targeted
  /// rescan can park an unconfirmed reconnect target alongside the hosts.
  /// The [_soloJoinSettle] delay is what keeps this honest — a second
  /// host arriving a moment later cancels the auto-join and hands the choice
  /// back to the user, who can also always Cancel out of the radar.
  void _considerSoloAutoJoin() {
    _soloJoinTimer?.cancel();
    if (state.connectingPeerId != null) return;
    final hosts = state.peers.where((p) => p.isAppHost).toList();
    if (hosts.length != 1) return;
    final only = hosts.single;
    _soloJoinTimer = Timer(_soloJoinSettle, () {
      if (isClosed || state.connectingPeerId != null) return;
      if (state.connectionState != BluetoothConnectionState.scanning) return;
      final current = state.peers.where((p) => p.isAppHost).toList();
      if (current.length != 1 || current.single.id != only.id) return;
      _connectTo(current.single);
    });
  }

  Future<void> connectTo(BluetoothPeer peer) {
    // A tap on a peer tile is an explicit choice — drop the background
    // auto-attempt semantics (including the persistent loop) so failures
    // surface normally again.
    _autoAttempt = false;
    _stopAutoJoin();
    return _connectTo(peer);
  }

  Future<void> _connectTo(BluetoothPeer peer) async {
    _reconnectTimeout?.cancel();
    _soloJoinTimer?.cancel();
    // A one-shot background attempt must stay guarded through the dial phase:
    // a hung connect has to fall back to role selection on its own. The
    // persistent auto-join loop ([_autoJoining]) owns its own timing, so it
    // must NOT arm this give-up timer.
    if (_autoAttempt && !_autoJoining) _armReconnectTimeout();
    emit(state.copyWith(connectingPeerId: peer.id));
    await _scanSub?.cancel();
    _scanSub = null;
    _transport.cancelDiscovery();
    await _transport.connectToHost(peer);
  }

  /// "Reconnect to the last session" — one tap from the role screen, or
  /// hands-free via [_maybeAutoReconnect]. Classic peers can be dialed cold
  /// by address; BLE peers must be rediscovered first, so those go through
  /// a targeted scan that auto-connects.
  Future<void> reconnectToLast() async {
    final peer = state.lastPeer;
    if (peer == null) return;

    if (!peer.isBle) {
      emit(
        state.copyWith(
          role: BluetoothRole.joiner,
          peers: [peer],
          connectingPeerId: peer.id,
        ),
      );
      _armReconnectTimeout();
      await _transport.connectToHost(peer);
      return;
    }

    emit(
      state.copyWith(
        role: BluetoothRole.joiner,
        peers: const [],
        connectingPeerId: peer.id,
      ),
    );
    await _listenToScan(autoConnectId: peer.id);
    _armReconnectTimeout();
  }

  void _armReconnectTimeout() {
    _reconnectTimeout?.cancel();
    _reconnectTimeout = Timer(const Duration(seconds: 25), () {
      if (isClosed ||
          state.connectionState == BluetoothConnectionState.connected) {
        return;
      }
      if (_autoAttempt) {
        // The background attempt ran out of time — give up quietly.
        backToRoleSelection();
      } else {
        // Peer never showed up — fall back to a normal scan so the user can
        // pick whatever IS around.
        emit(state.copyWith(connectingPeerId: null));
      }
    });
  }

  void backToRoleSelection() {
    _autoAttempt = false;
    _stopAutoJoin();
    _reconnectTimeout?.cancel();
    _discoverableTimer?.cancel();
    _soloJoinTimer?.cancel();
    _scanSub?.cancel();
    _scanSub = null;
    _transport.reset();
    emit(
      BluetoothConnectState.initial().copyWith(
        myName: state.myName,
        lastPeer: state.lastPeer,
      ),
    );
  }

  @override
  Future<void> close() async {
    _stopAutoJoin();
    _reconnectTimeout?.cancel();
    _discoverableTimer?.cancel();
    _soloJoinTimer?.cancel();
    await _connectionSub?.cancel();
    await _scanSub?.cancel();
    await _bleAdvertisingSub?.cancel();
    return super.close();
  }
}

class BluetoothConnectState extends Equatable {
  final BluetoothRole? role;
  final BluetoothConnectionState connectionState;
  final List<BluetoothPeer> peers;

  /// This device's display name (what the other side will see while we
  /// host), for the beacon screen.
  final String myName;

  /// The peer of the last successful join, for the quick-reconnect card.
  final BluetoothPeer? lastPeer;

  /// The peer currently being connected to (Join flow only), so the UI can
  /// show a loading indicator on that specific list tile. `null` means no
  /// connection attempt is in flight — note this must be explicitly
  /// clearable, so [copyWith] takes it as a plain positional-ish named
  /// param rather than the usual `x ?? this.x` pattern.
  final String? connectingPeerId;

  /// True once BLE advertising failed to start while hosting — iPhones can't
  /// discover this device over Bluetooth, so the UI offers the Wi-Fi bridge.
  final bool bleUnavailable;

  /// Whether a scanning phone can currently find this one (host role only).
  /// Android grants discoverability for a fixed window; when it lapses the
  /// beacon keeps pulsing but nobody can see it, so the UI offers a re-arm.
  final bool hostDiscoverable;

  const BluetoothConnectState({
    required this.role,
    required this.connectionState,
    required this.peers,
    required this.myName,
    required this.lastPeer,
    required this.connectingPeerId,
    required this.bleUnavailable,
    required this.hostDiscoverable,
  });

  factory BluetoothConnectState.initial() => const BluetoothConnectState(
    role: null,
    connectionState: BluetoothConnectionState.disconnected,
    peers: [],
    myName: '',
    lastPeer: null,
    connectingPeerId: null,
    bleUnavailable: false,
    hostDiscoverable: true,
  );

  BluetoothConnectState copyWith({
    BluetoothRole? role,
    BluetoothConnectionState? connectionState,
    List<BluetoothPeer>? peers,
    String? myName,
    BluetoothPeer? lastPeer,
    Object? connectingPeerId = _unset,
    bool? bleUnavailable,
    bool? hostDiscoverable,
  }) => BluetoothConnectState(
    role: role ?? this.role,
    connectionState: connectionState ?? this.connectionState,
    peers: peers ?? this.peers,
    myName: myName ?? this.myName,
    lastPeer: lastPeer ?? this.lastPeer,
    connectingPeerId: identical(connectingPeerId, _unset)
        ? this.connectingPeerId
        : connectingPeerId as String?,
    bleUnavailable: bleUnavailable ?? this.bleUnavailable,
    hostDiscoverable: hostDiscoverable ?? this.hostDiscoverable,
  );

  @override
  List<Object?> get props => [
    role,
    connectionState,
    peers,
    myName,
    lastPeer,
    connectingPeerId,
    bleUnavailable,
    hostDiscoverable,
  ];
}

const _unset = Object();
