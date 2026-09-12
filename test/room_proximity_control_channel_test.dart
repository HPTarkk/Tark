import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

void main() {
  const token = '0123456789abcdef0123456789abcdef';

  test('host does not expose an unusable invite when discoverability is denied', () async {
    final engine = _FakeClassicBluetoothEngine(discoverable: false);
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    await expectLater(
      channel.host(rendezvousToken: token),
      throwsA(isA<StateError>()),
    );
    expect(engine.hosted, isFalse);
  });

  test('failed RFCOMM dial fails the join instead of waiting forever', () async {
    final engine = _FakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    engine.scans.add(
      BluetoothPeer(
        id: 'AA:BB:CC:DD:EE:FF',
        name: RoomProximityControlChannel.rendezvousName(token),
        isAppHost: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(engine.dialed, isTrue);

    engine.errors.add('connect_failed');
    await expectLater(joining, throwsA(isA<StateError>()));
  });

  test('peer connected event completes the proximity dial', () async {
    final engine = _FakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    engine.scans.add(
      BluetoothPeer(
        id: 'AA:BB:CC:DD:EE:FF',
        name: RoomProximityControlChannel.rendezvousName(token),
        isAppHost: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    engine.connected.add('AA:BB:CC:DD:EE:FF');

    await joining;
    expect(engine.dialed, isTrue);
  });
}

class _FakeClassicBluetoothEngine extends ClassicBluetoothEngine {
  _FakeClassicBluetoothEngine({this.discoverable = true});

  final bool discoverable;
  final scans = StreamController<BluetoothPeer>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final incoming = StreamController<Uint8List>.broadcast();

  bool hosted = false;
  bool dialed = false;

  @override
  Stream<Uint8List> get input => incoming.stream;

  @override
  Stream<String> get onPeerConnected => connected.stream;

  @override
  Stream<String> get onError => errors.stream;

  @override
  Stream<void> get onClosed => closed.stream;

  @override
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async =>
      discoverable;

  @override
  Future<void> startHosting({String name = 'tark'}) async {
    hosted = true;
  }

  @override
  Stream<BluetoothPeer> scanForHosts() => scans.stream;

  @override
  void cancelDiscovery() {}

  @override
  Future<void> connectToHost(String address) async {
    dialed = true;
  }

  @override
  Future<void> write(Uint8List bytes) async {}

  @override
  Future<void> dispose() async {
    await scans.close();
    await connected.close();
    await errors.close();
    await closed.close();
    await incoming.close();
  }
}
