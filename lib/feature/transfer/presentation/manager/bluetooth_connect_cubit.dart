import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

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
  }

  Future<void> startHosting() async {
    emit(state.copyWith(role: BluetoothRole.host, peers: const []));
    await _transport.startHosting();
  }

  Future<void> startScanning() async {
    emit(state.copyWith(role: BluetoothRole.joiner, peers: const []));
    await _scanSub?.cancel();
    _scanSub = _transport.scanForHosts().listen(
      (peer) {
        if (state.peers.any((p) => p.id == peer.id)) return;
        emit(state.copyWith(peers: [...state.peers, peer]));
      },
      onError: (Object e) => Logger.log('BT scan error: $e'),
    );
  }

  Future<void> connectTo(BluetoothPeer peer) async {
    emit(state.copyWith(connectingPeerId: peer.id));
    await _scanSub?.cancel();
    _transport.cancelDiscovery();
    await _transport.connectToHost(peer);
  }

  void backToRoleSelection() {
    _scanSub?.cancel();
    _transport.reset();
    emit(BluetoothConnectState.initial());
  }

  @override
  Future<void> close() async {
    await _connectionSub?.cancel();
    await _scanSub?.cancel();
    return super.close();
  }
}

class BluetoothConnectState extends Equatable {
  final BluetoothRole? role;
  final BluetoothConnectionState connectionState;
  final List<BluetoothPeer> peers;

  /// The peer currently being connected to (Join flow only), so the UI can
  /// show a loading indicator on that specific list tile. `null` means no
  /// connection attempt is in flight — note this must be explicitly
  /// clearable, so [copyWith] takes it as a plain positional-ish named
  /// param rather than the usual `x ?? this.x` pattern.
  final String? connectingPeerId;

  const BluetoothConnectState({
    required this.role,
    required this.connectionState,
    required this.peers,
    required this.connectingPeerId,
  });

  factory BluetoothConnectState.initial() => const BluetoothConnectState(
        role: null,
        connectionState: BluetoothConnectionState.disconnected,
        peers: [],
        connectingPeerId: null,
      );

  BluetoothConnectState copyWith({
    BluetoothRole? role,
    BluetoothConnectionState? connectionState,
    List<BluetoothPeer>? peers,
    Object? connectingPeerId = _unset,
  }) =>
      BluetoothConnectState(
        role: role ?? this.role,
        connectionState: connectionState ?? this.connectionState,
        peers: peers ?? this.peers,
        connectingPeerId: identical(connectingPeerId, _unset)
            ? this.connectingPeerId
            : connectingPeerId as String?,
      );

  @override
  List<Object?> get props => [role, connectionState, peers, connectingPeerId];
}

const _unset = Object();
