import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/sfx/sfx_player.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart';
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart';

class _Transport implements BluetoothTransport {
  final states = StreamController<BluetoothConnectionState>.broadcast(
    sync: true,
  );
  final peers = StreamController<BluetoothPeer>.broadcast(sync: true);
  final dials = <String>[];
  @override
  Stream<BluetoothConnectionState> get connectionState => states.stream;
  @override
  Stream<bool> get bleAdvertising => const Stream.empty();
  @override
  Stream<BluetoothPeer> scanForHosts() {
    states.add(BluetoothConnectionState.scanning);
    return peers.stream;
  }

  @override
  Future<void> connectToHost(BluetoothPeer peer) async {
    dials.add(peer.id);
    states.add(BluetoothConnectionState.connected);
  }

  @override
  void reset() {}
  @override
  void cancelDiscovery() {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Settings implements SettingsRepository {
  @override
  Future<String> getMyName() async => 'Me';
  @override
  Future<String?> getLastBluetoothPeerId() async => null;
  @override
  Future<String?> getLastBluetoothPeerName() async => null;
  @override
  Future<bool> getAutoReconnectEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Sfx implements SfxPlayer {
  @override
  dynamic noSuchMethod(Invocation i) {}
}

void main() {
  for (final multiple in [false, true]) {
    test(
      multiple
          ? 'a second host keeps the choice manual'
          : 'repeated signal reports cannot postpone the solo connection',
      () async {
        final transport = _Transport();
        final cubit = BluetoothConnectCubit(transport, _Settings(), _Sfx())
          ..scanLocationReady = (() async => true);
        await cubit.startScanning();
        addTearDown(() async {
          await cubit.close();
          await transport.states.close();
          await transport.peers.close();
        });
        expect(cubit.state.connectionState, BluetoothConnectionState.scanning);
        for (var i = 0; i < 4; i++) {
          transport.peers.add(
            BluetoothPeer(
              id: 'aa',
              name: 'Nazanin',
              isAppHost: true,
              rssi: -60 + i,
            ),
          );
          if (multiple && i == 1) {
            transport.peers.add(
              const BluetoothPeer(id: 'bb', name: 'Second', isAppHost: true),
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(transport.dials, multiple ? isEmpty : ['aa']);
      },
    );
  }
}
