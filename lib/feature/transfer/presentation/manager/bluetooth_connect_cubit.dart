import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/utils/logger.dart';
import '../../domain/entity/bluetooth_connection_state.dart';
import '../../domain/entity/bluetooth_peer.dart';
import '../../domain/entity/bluetooth_role.dart';
import '../../domain/repository/bluetooth_transport.dart';

@injectable
class BluetoothConnectCubit extends Cubit<BluetoothConnectState> {
  final BluetoothTransport _transport;

  StreamSubscription<BluetoothConnectionState>? _connectionSub;
  StreamSubscription<BluetoothPeer>? _scanSub;
  StreamSubscription<bool>? _bleAdvertisingSub;
  Timer? _reconnectTimeout;

  BluetoothConnectCubit(this._transport)
      : super(BluetoothConnectState.initial()) {
    _connectionSub = _transport.connectionState.listen(
      (s) {
        // Clear the "connecting to this peer" marker once the attempt
        // resolves either way, so a failed connection can be retried.
        final stillConnecting = s == BluetoothConnectionState.connecting;
        emit(state.copyWith(
          connectionState: s,
          connectingPeerId: stillConnecting ? state.connectingPeerId : null,
        ));
      },
      onError: (Object e) => Logger.log('BT connection state error: $e'),
    );
    // When BLE host advertising can't start, iPhones can't discover us — flag
    // it so the host screen can steer the user to the Wi-Fi hotspot bridge.
    _bleAdvertisingSub = _transport.bleAdvertising.listen(
      (ok) {
        if (!ok && !isClosed) emit(state.copyWith(bleUnavailable: true));
      },
      onError: (Object e) => Logger.log('BLE advertising state error: $e'),
    );
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    if (isClosed) return;
    final lastId = prefs.getString('bt_last_peer_id');
    final lastName = prefs.getString('bt_last_peer_name');
    emit(state.copyWith(
      myName: prefs.getString('user_name') ?? 'Tark',
      lastPeer: lastId != null
          ? BluetoothPeer(id: lastId, name: lastName ?? lastId)
          : null,
    ));
  }

  Future<void> startHosting() async {
    emit(state.copyWith(role: BluetoothRole.host, peers: const []));
    await _transport.startHosting();
  }

  Future<void> startScanning() async {
    emit(state.copyWith(role: BluetoothRole.joiner, peers: const []));
    await _listenToScan();
  }

  Future<void> _listenToScan({String? autoConnectId}) async {
    await _scanSub?.cancel();
    _scanSub = _transport.scanForHosts().listen(
      (peer) {
        // Upsert: repeat discoveries refresh the RSSI, so the signal bars
        // (and the radar blip distance) stay live while scanning.
        final peers = [...state.peers];
        final idx = peers.indexWhere((p) => p.id == peer.id);
        if (idx >= 0) {
          peers[idx] = peer;
        } else {
          peers.add(peer);
        }
        peers.sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
        emit(state.copyWith(peers: peers));

        if (autoConnectId != null &&
            peer.id == autoConnectId &&
            state.connectingPeerId == autoConnectId &&
            state.connectionState != BluetoothConnectionState.connecting) {
          connectTo(peer);
        }
      },
      onError: (Object e) => Logger.log('BT scan error: $e'),
    );
  }

  Future<void> connectTo(BluetoothPeer peer) async {
    _reconnectTimeout?.cancel();
    emit(state.copyWith(connectingPeerId: peer.id));
    await _scanSub?.cancel();
    _transport.cancelDiscovery();
    await _transport.connectToHost(peer);
  }

  /// One-tap "reconnect to the last session" from the role screen. Classic
  /// peers can be dialed cold by address; BLE peers must be rediscovered
  /// first, so those go through a targeted scan that auto-connects.
  Future<void> reconnectToLast() async {
    final peer = state.lastPeer;
    if (peer == null) return;

    if (!peer.isBle) {
      emit(state.copyWith(
        role: BluetoothRole.joiner,
        peers: [peer],
        connectingPeerId: peer.id,
      ));
      await _transport.connectToHost(peer);
      return;
    }

    emit(state.copyWith(
      role: BluetoothRole.joiner,
      peers: const [],
      connectingPeerId: peer.id,
    ));
    await _listenToScan(autoConnectId: peer.id);
    _reconnectTimeout?.cancel();
    _reconnectTimeout = Timer(const Duration(seconds: 25), () {
      // Peer never showed up — fall back to a normal scan so the user can
      // pick whatever IS around.
      if (!isClosed &&
          state.connectionState != BluetoothConnectionState.connected) {
        emit(state.copyWith(connectingPeerId: null));
      }
    });
  }

  void backToRoleSelection() {
    _reconnectTimeout?.cancel();
    _scanSub?.cancel();
    _transport.reset();
    emit(BluetoothConnectState.initial()
        .copyWith(myName: state.myName, lastPeer: state.lastPeer));
  }

  @override
  Future<void> close() async {
    _reconnectTimeout?.cancel();
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

  const BluetoothConnectState({
    required this.role,
    required this.connectionState,
    required this.peers,
    required this.myName,
    required this.lastPeer,
    required this.connectingPeerId,
    required this.bleUnavailable,
  });

  factory BluetoothConnectState.initial() => const BluetoothConnectState(
        role: null,
        connectionState: BluetoothConnectionState.disconnected,
        peers: [],
        myName: '',
        lastPeer: null,
        connectingPeerId: null,
        bleUnavailable: false,
      );

  BluetoothConnectState copyWith({
    BluetoothRole? role,
    BluetoothConnectionState? connectionState,
    List<BluetoothPeer>? peers,
    String? myName,
    BluetoothPeer? lastPeer,
    Object? connectingPeerId = _unset,
    bool? bleUnavailable,
  }) =>
      BluetoothConnectState(
        role: role ?? this.role,
        connectionState: connectionState ?? this.connectionState,
        peers: peers ?? this.peers,
        myName: myName ?? this.myName,
        lastPeer: lastPeer ?? this.lastPeer,
        connectingPeerId: identical(connectingPeerId, _unset)
            ? this.connectingPeerId
            : connectingPeerId as String?,
        bleUnavailable: bleUnavailable ?? this.bleUnavailable,
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
      ];
}

const _unset = Object();
