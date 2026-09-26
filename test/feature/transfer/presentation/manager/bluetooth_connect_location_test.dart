import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/analytics/analytics.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/sfx/sfx_player.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_role.dart';
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart';
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart';

class _Transport implements BluetoothTransport {
  int scans = 0;

  @override
  Stream<BluetoothConnectionState> get connectionState => const Stream.empty();

  @override
  Stream<bool> get bleAdvertising => const Stream.empty();

  @override
  Stream<BluetoothPeer> scanForHosts() {
    scans++;
    return const Stream.empty();
  }

  @override
  void reset() {}

  @override
  void cancelDiscovery() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sfx implements SfxPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

class _Analytics implements Analytics {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

void main() {
  late _Transport transport;
  late BluetoothConnectCubit cubit;
  var locationOn = true;

  setUp(() {
    transport = _Transport();
    locationOn = true;
    cubit = BluetoothConnectCubit(transport, _Settings(), _Sfx(), _Analytics())
      ..scanLocationReady = (() async => locationOn);
  });

  tearDown(() => cubit.close());

  test('with Location on, the joiner searches', () async {
    await cubit.startScanning();

    expect(cubit.state.role, BluetoothRole.joiner);
    expect(cubit.state.locationOff, isFalse);
    expect(transport.scans, 1);
  });

  test('with Location off, the joiner asks for it instead of searching '
      'for nobody', () async {
    locationOn = false;

    await cubit.startScanning();

    expect(cubit.state.role, BluetoothRole.joiner);
    expect(cubit.state.locationOff, isTrue);
    expect(transport.scans, 0);
  });

  test('turning Location on and coming back starts the search', () async {
    locationOn = false;
    await cubit.startScanning();

    await cubit.recheckLocation();
    expect(transport.scans, 0, reason: 'still off');

    locationOn = true;
    await cubit.recheckLocation();

    expect(cubit.state.locationOff, isFalse);
    expect(transport.scans, 1);
  });

  test('backing out clears the Location note', () async {
    locationOn = false;
    await cubit.startScanning();

    cubit.backToRoleSelection();

    expect(cubit.state.role, isNull);
    expect(cubit.state.locationOff, isFalse);
  });
}
