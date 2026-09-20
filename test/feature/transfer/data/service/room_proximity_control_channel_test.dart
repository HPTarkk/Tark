import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

void main() {
  const token = '0123456789abcdef0123456789abcdef';

  test(
    'host prepares native readiness before discoverability and cleans denial',
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
      expect(engine.hosted, isTrue);
      expect(engine.stopped, isTrue);
      expect(engine.events, orderedEquals(['host', 'discoverability', 'stop']));
    },
  );

  test(
    'host readiness is complete before discoverability is requested',
    () async {
      final engine = _FakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      await channel.host(rendezvousToken: token);

      expect(engine.events, orderedEquals(['host', 'discoverability']));
      expect(engine.hosted, isTrue);
      expect(engine.stopped, isFalse);
    },
  );

  test('native host setup failure never requests discoverability', () async {
    final engine = _FakeClassicBluetoothEngine(failHosting: true);
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    await expectLater(
      channel.host(rendezvousToken: token),
      throwsA(
        isA<RoomProximityException>().having(
          (error) => error.failure,
          'failure',
          RoomProximityFailure.hostSetupFailed,
        ),
      ),
    );

    expect(engine.events, orderedEquals(['host', 'stop']));
    expect(engine.stopped, isTrue);
  });

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
          rendezvousMatched: true,
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

  test(
    'a native dial future that never returns is cancelled by the deadline',
    () async {
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
    },
  );

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

  test(
    'exact adapter name without BLE binding is never accepted',
    () async {
      final engine = _FakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(
        engine: engine,
        findTimeout: const Duration(milliseconds: 40),
        rescanEvery: const Duration(milliseconds: 15),
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
            RoomProximityFailure.hostNotFound,
          ),
        ),
      );
      expect(engine.dialed, isFalse);
    },
  );

  test(
    'native discoverability error is host setup failure, not user denial',
    () async {
      final engine = _FakeClassicBluetoothEngine(failDiscoverability: true);
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      await expectLater(
        channel.host(rendezvousToken: token),
        throwsA(
          isA<RoomProximityException>().having(
            (error) => error.failure,
            'failure',
            RoomProximityFailure.hostSetupFailed,
          ),
        ),
      );
      expect(engine.stopped, isTrue);
    },
  );

  test(
    'BLE-bound candidate is accepted even when adapter name is stale',
    () async {
      final engine = _FakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      addTearDown(channel.dispose);

      final joining = channel.connect(rendezvousToken: token);
      await Future<void>.delayed(Duration.zero);
      engine.scans.add(
        const BluetoothPeer(
          id: 'AA:BB:CC:DD:EE:FF',
          name: 'Old OEM Name',
          isAppHost: true,
          rendezvousMatched: true,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      engine.connected.add('AA:BB:CC:DD:EE:FF');

      await joining;
      expect(engine.dialed, isTrue);
    },
  );

  test('scan errors are typed instead of becoming host-not-found', () async {
    final engine = _FakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    addTearDown(channel.dispose);

    final joining = channel.connect(rendezvousToken: token);
    await Future<void>.delayed(Duration.zero);
    engine.scans.addError(StateError('native scan failed'));

    await expectLater(
      joining,
      throwsA(
        isA<RoomProximityException>().having(
          (error) => error.failure,
          'failure',
          RoomProximityFailure.scanFailed,
        ),
      ),
    );
  });

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
    this.failHosting = false,
    this.failDiscoverability = false,
  });

  final bool discoverable;
  final bool enabled;
  final bool blockDial;
  final bool failHosting;
  final bool failDiscoverability;
  final events = <String>[];
  final scans = StreamController<BluetoothPeer>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final incoming = StreamController<Uint8List>.broadcast();

  bool hosted = false;
  bool stopped = false;
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
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async {
    events.add('discoverability');
    if (failDiscoverability) {
      throw StateError('native discoverability failed');
    }
    return discoverable;
  }

  @override
  Future<void> startHosting({String name = 'tark'}) async {
    events.add('host');
    hosted = true;
    if (failHosting) throw StateError('native host setup failed');
  }

  @override
  Future<void> stopHosting() async {
    events.add('stop');
    stopped = true;
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
