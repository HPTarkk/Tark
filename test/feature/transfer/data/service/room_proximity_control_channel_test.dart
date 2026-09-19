import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

void main() {
  const token = '0123456789abcdef0123456789abcdef';

  test(
    'host does not expose an unusable invite when discoverability is denied',
    () async {
      final engine = _FakeClassicBluetoothEngine(discoverable: false);
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      await expectLater(
        channel.host(rendezvousToken: token),
        throwsA(isA<StateError>()),
      );
      expect(engine.hosted, isFalse);
    },
  );

  test(
    'failed RFCOMM dial fails the join instead of waiting forever',
    () async {
      final engine = _FakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      final joining = channel.connect(rendezvousToken: token);
      // The adapter check runs before the scan subscribes.
      await Future<void>.delayed(Duration.zero);
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
    },
  );

  test(
    'a host that never turns up fails the join instead of scanning forever',
    () async {
      final engine = _FakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(
        engine: engine,
        findTimeout: const Duration(milliseconds: 80),
        rescanEvery: const Duration(milliseconds: 15),
      );
      addTearDown(channel.dispose);

      await expectLater(
        channel.connect(rendezvousToken: token),
        throwsA(
          isA<RoomProximityException>().having(
            (error) => error.failure,
            'failure',
            RoomProximityFailure.hostNotFound,
          ),
        ),
      );
      // Discovery is restarted through Android's inquiry window rather than
      // left to end on its own after the first one.
      expect(engine.scanCount, greaterThan(1));
      expect(engine.dialed, isFalse);
    },
  );

  test('a connected event that never arrives is bounded too', () async {
    final engine = _FakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(
      engine: engine,
      dialTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    await Future<void>.delayed(Duration.zero);
    engine.scans.add(
      BluetoothPeer(
        id: 'AA:BB:CC:DD:EE:FF',
        name: RoomProximityControlChannel.rendezvousName(token),
        isAppHost: true,
      ),
    );

    await expectLater(
      joining,
      throwsA(
        isA<RoomProximityException>().having(
          (error) => error.failure,
          'failure',
          RoomProximityFailure.dialFailed,
        ),
      ),
    );
    expect(engine.dialed, isTrue);
  });

  test('a native dial future that never returns is cancelled by the deadline', (
    ) async {
    final engine = _FakeClassicBluetoothEngine(blockDial: true);
    final channel = RoomProximityControlChannel(
      engine: engine,
      dialTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    await Future<void>.delayed(Duration.zero);
    engine.scans.add(
      BluetoothPeer(
        id: 'AA:BB:CC:DD:EE:FF',
        name: RoomProximityControlChannel.rendezvousName(token),
        isAppHost: true,
      ),
    );

    await expectLater(
      joining,
      throwsA(
        isA<RoomProximityException>().having(
          (error) => error.failure,
          'failure',
          RoomProximityFailure.dialFailed,
        ),
      ),
    );
    expect(engine.dialed, isTrue);
    expect(engine.resetCalled, isTrue);
  });

  test('Bluetooth left off is reported before any scan starts', () async {
    final engine = _FakeClassicBluetoothEngine(enabled: false);
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    await expectLater(
      channel.connect(rendezvousToken: token),
      throwsA(
        isA<RoomProximityException>().having(
          (error) => error.failure,
          'failure',
          RoomProximityFailure.bluetoothOff,
        ),
      ),
    );
    expect(engine.scanned, isFalse);
  });

  test(
    'a declined visibility prompt says so, not just that it failed',
    () async {
      final engine = _FakeClassicBluetoothEngine(discoverable: false);
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      await expectLater(
        channel.host(rendezvousToken: token),
        throwsA(
          isA<RoomProximityException>().having(
            (error) => error.failure,
            'failure',
            RoomProximityFailure.discoverabilityDenied,
          ),
        ),
      );
    },
  );

  test('peer connected event completes the proximity dial', () async {
    final engine = _FakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    await Future<void>.delayed(Duration.zero);
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
  _FakeClassicBluetoothEngine({
    this.discoverable = true,
    this.enabled = true,
    this.blockDial = false,
  });

  final bool discoverable;
  final bool enabled;
  final bool blockDial;
  final scans = StreamController<BluetoothPeer>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final incoming = StreamController<Uint8List>.broadcast();

  bool hosted = false;
  bool dialed = false;
  bool resetCalled = false;
  int scanCount = 0;

  bool get scanned => scanCount > 0;

  @override
  Future<bool> get isEnabled async => enabled;

  @override
  Future<bool> requestEnable() async => false;

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
  Stream<BluetoothPeer> scanForHosts() {
    scanCount++;
    return scans.stream;
  }

  @override
  void cancelDiscovery() {}

  @override
  Future<void> connectToHost(String address) async {
    dialed = true;
    if (blockDial) await Completer<void>().future;
  }

  @override
  Future<void> reset() async {
    resetCalled = true;
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
