import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_control_session_registry.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_join_carrier.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/entity/room_transport_choice.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/bluetooth/length_prefixed_framer.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

void main() {
  const roomId = RoomId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  const invitationId = '0123456789abcdef0123456789abcdef';
  final invitation = RoomInvitation(
    version: RoomInvitation.currentVersion,
    roomId: roomId,
    invitationId: invitationId,
    secret: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    kind: RoomInvitationKind.trustedMembership,
    issuedAt: DateTime.utc(2026, 9, 12),
    expiresAt: DateTime.utc(2026, 9, 13),
    singleUse: false,
    displayCode: roomInviteDisplayCode(roomId, invitationId),
  );

  setUp(() async {
    await RoomProximityControlSessionRegistry.instance.clear();
  });
  tearDown(() async {
    await RoomProximityControlSessionRegistry.instance.clear();
  });

  test(
    'joiner requests transport and accepts host-authoritative credentials',
    () async {
      final engine = _RegistryFakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      await channel.host(rendezvousToken: invitationId);
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: roomId,
        invitation: invitation,
        channel: channel,
      );

      final waiting = RoomProximityControlSessionRegistry.instance
          .waitForHotspot(
            roomId: roomId,
            transportEpoch: 7,
            timeout: const Duration(seconds: 1),
          );
      await Future<void>.delayed(Duration.zero);

      final request = _decodeSingleWrite(engine);
      expect(request.kind, 'transportRequest');
      expect(request.requestId, '00000000000000000000000000000007');

      const credentials = HotspotCredentials(
        ssid: 'DIRECT-TARK',
        passphrase: 'room-secret',
      );
      engine.addEnvelope(
        RoomProximityEnvelope(
          kind: 'transportCredentials',
          roomId: roomId.value,
          requestId: '00000000000000000000000000000001',
          joinEpoch: invitationId,
          payload: jsonEncode({
            'ssid': credentials.ssid,
            'passphrase': credentials.passphrase,
            'security': credentials.security,
          }),
        ),
      );

      expect(await waiting, credentials);
    },
  );

  test(
    'a timed-out join wait is cleared so retry sends a fresh request',
    () async {
      final engine = _RegistryFakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      await channel.host(rendezvousToken: invitationId);
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: roomId,
        invitation: invitation,
        channel: channel,
      );

      final first = RoomProximityControlSessionRegistry.instance.waitForHotspot(
        roomId: roomId,
        transportEpoch: 1,
        timeout: Duration.zero,
      );
      await expectLater(first, throwsA(isA<TimeoutException>()));

      final second = RoomProximityControlSessionRegistry.instance
          .waitForHotspot(
            roomId: roomId,
            transportEpoch: 2,
            timeout: const Duration(seconds: 1),
          );
      await Future<void>.delayed(Duration.zero);

      expect(engine.writes, hasLength(2));
      expect(
        _decodeWrite(engine, 1).requestId,
        '00000000000000000000000000000002',
      );

      engine.addEnvelope(
        RoomProximityEnvelope(
          kind: 'transportCredentials',
          roomId: roomId.value,
          requestId: '00000000000000000000000000000001',
          joinEpoch: invitationId,
          payload: jsonEncode(const {
            'ssid': 'DIRECT-TARK',
            'passphrase': 'room-secret',
            'security': 'WPA2',
          }),
        ),
      );
      expect((await second).ssid, 'DIRECT-TARK');
    },
  );

  test(
    'live host answers a new member without rebuilding the hotspot',
    () async {
      final engine = _RegistryFakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      await channel.host(rendezvousToken: invitationId);
      const credentials = HotspotCredentials(
        ssid: 'DIRECT-LIVE',
        passphrase: 'already-running',
      );
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: roomId,
        invitation: invitation,
        channel: channel,
        currentHotspotCredentials: () => credentials,
      );

      engine.addEnvelope(
        const RoomProximityEnvelope(
          kind: 'transportRequest',
          roomId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          requestId: '00000000000000000000000000000009',
          joinEpoch: invitationId,
          payload: '{}',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final response = _decodeSingleWrite(engine);
      expect(response.kind, 'transportCredentials');
      final payload = jsonDecode(response.payload) as Map<String, dynamic>;
      expect(payload['ssid'], credentials.ssid);
      expect(payload['passphrase'], credentials.passphrase);
      expect(payload['security'], credentials.security);
    },
  );

  Future<_RegistryFakeClassicBluetoothEngine> adopted() async {
    final engine = _RegistryFakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    await channel.host(rendezvousToken: invitationId);
    await RoomProximityControlSessionRegistry.instance.adopt(
      roomId: roomId,
      invitation: invitation,
      channel: channel,
    );
    return engine;
  }

  RoomProximityEnvelope declined() => RoomProximityEnvelope(
    kind: 'transportHostDeclined',
    roomId: roomId.value,
    requestId: '00000000000000000000000000000001',
    joinEpoch: invitationId,
    payload: '{}',
  );

  group('an invite nobody answered is not a link', () {
    Future<_RegistryFakeClassicBluetoothEngine> issued() async {
      final engine = _RegistryFakeClassicBluetoothEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      await channel.host(rendezvousToken: invitationId);
      await RoomProximityControlSessionRegistry.instance.adopt(
        roomId: roomId,
        invitation: invitation,
        channel: channel,
        issuer: true,
      );
      return engine;
    }

    test('a QR on screen with nobody connected does not count', () async {
      await issued();
      final registry = RoomProximityControlSessionRegistry.instance;
      expect(registry.hasRoom(roomId), isFalse);
      expect(registry.isIssuerFor(roomId), isNull);
    });

    test('the joining phone speaking makes it a link', () async {
      final engine = await issued();
      engine.addEnvelope(declined());
      await Future<void>.delayed(Duration.zero);
      final registry = RoomProximityControlSessionRegistry.instance;
      expect(registry.hasRoom(roomId), isTrue);
      expect(registry.isIssuerFor(roomId), isTrue);
    });

    test('a joiner adopts after dialing, so it is linked at once', () async {
      await adopted();
      final registry = RoomProximityControlSessionRegistry.instance;
      expect(registry.hasRoom(roomId), isTrue);
      expect(registry.isIssuerFor(roomId), isFalse);
    });
  });

  test('a phone that cannot host says so over the control socket', () async {
    final engine = await adopted();

    await RoomProximityControlSessionRegistry.instance.declineHotspotHost(
      roomId: roomId,
    );

    expect(_decodeSingleWrite(engine).kind, 'transportHostDeclined');
  });

  test('a waiting joiner hears the decline instead of timing out', () async {
    final engine = await adopted();
    final waiting = RoomProximityControlSessionRegistry.instance.waitForHotspot(
      roomId: roomId,
      transportEpoch: 1,
      timeout: const Duration(seconds: 5),
    );
    await Future<void>.delayed(Duration.zero);

    engine.addEnvelope(declined());

    await expectLater(waiting, throwsA(isA<RoomHotspotHostDeclined>()));
  });

  test('a decline that lands before the wait is not lost', () async {
    final engine = await adopted();
    engine.addEnvelope(declined());
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      RoomProximityControlSessionRegistry.instance.waitForHotspot(
        roomId: roomId,
        transportEpoch: 1,
        timeout: const Duration(seconds: 5),
      ),
      throwsA(isA<RoomHotspotHostDeclined>()),
    );
  });
  Future<_RegistryFakeClassicBluetoothEngine> adoptSession({
    RoomTransportChoice local = RoomTransportChoice.automatic,
  }) async {
    RoomProximityControlSessionRegistry.instance.localChoice = () => local;
    addTearDown(
      () =>
          RoomProximityControlSessionRegistry.instance.localChoice = () =>
              RoomTransportChoice.automatic,
    );
    final engine = _RegistryFakeClassicBluetoothEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    await channel.host(rendezvousToken: invitationId);
    await RoomProximityControlSessionRegistry.instance.adopt(
      roomId: roomId,
      invitation: invitation,
      channel: channel,
    );
    await Future<void>.delayed(Duration.zero);
    return engine;
  }

  RoomProximityEnvelope choice(RoomTransportChoice value) =>
      RoomProximityEnvelope(
        kind: 'transportPreference',
        roomId: roomId.value,
        requestId: '00000000000000000000000000000001',
        joinEpoch: invitationId,
        payload: jsonEncode({'choice': value.key}),
      );

  Future<bool> agree({
    required RoomTransportChoice local,
    RoomTransportChoice? peer,
  }) async {
    final engine = await adoptSession(local: local);
    if (peer != null) engine.addEnvelope(choice(peer));
    await Future<void>.delayed(Duration.zero);
    return RoomProximityControlSessionRegistry.instance.agreeOnBluetooth(
      roomId: roomId,
      timeout: Duration.zero,
    );
  }

  group('agreeOnBluetooth', () {
    test('a linked phone tells the other its choice once, up front', () async {
      final engine = await adoptSession(local: RoomTransportChoice.bluetooth);
      expect(engine.preferences, hasLength(1));
      expect(jsonDecode(engine.preferences.single.payload), {
        'choice': 'bluetooth',
      });

      // Planning does not send it again.
      await RoomProximityControlSessionRegistry.instance.agreeOnBluetooth(
        roomId: roomId,
        timeout: Duration.zero,
      );
      expect(engine.preferences, hasLength(1));
    });

    test('waits briefly for an answer still in flight', () async {
      final engine = await adoptSession();
      final agreed = RoomProximityControlSessionRegistry.instance
          .agreeOnBluetooth(roomId: roomId);
      await Future<void>.delayed(Duration.zero);
      engine.addEnvelope(choice(RoomTransportChoice.bluetooth));
      expect(await agreed, isTrue);
    });

    test(
      'Bluetooth on one phone and automatic on the other: Bluetooth',
      () async {
        expect(
          await agree(
            local: RoomTransportChoice.bluetooth,
            peer: RoomTransportChoice.automatic,
          ),
          isTrue,
        );
        await RoomProximityControlSessionRegistry.instance.clear();
        expect(
          await agree(
            local: RoomTransportChoice.automatic,
            peer: RoomTransportChoice.bluetooth,
          ),
          isTrue,
        );
      },
    );

    test('Wi-Fi/Hotspot on either phone wins over Bluetooth', () async {
      expect(
        await agree(
          local: RoomTransportChoice.bluetooth,
          peer: RoomTransportChoice.hotspot,
        ),
        isFalse,
      );
      await RoomProximityControlSessionRegistry.instance.clear();
      expect(
        await agree(
          local: RoomTransportChoice.hotspot,
          peer: RoomTransportChoice.bluetooth,
        ),
        isFalse,
      );
    });

    test('a silent peer counts as automatic', () async {
      expect(await agree(local: RoomTransportChoice.bluetooth), isTrue);
      await RoomProximityControlSessionRegistry.instance.clear();
      expect(await agree(local: RoomTransportChoice.automatic), isFalse);
    });
  });
}

RoomProximityEnvelope _decodeSingleWrite(
  _RegistryFakeClassicBluetoothEngine engine,
) {
  expect(engine.writes, hasLength(1));
  final frames = FrameReassembler().addBytes(engine.writes.single);
  expect(frames, hasLength(1));
  return RoomProximityEnvelope.decode(utf8.decode(frames.single));
}

RoomProximityEnvelope _decodeWrite(
  _RegistryFakeClassicBluetoothEngine engine,
  int index,
) {
  final frames = FrameReassembler().addBytes(engine.writes[index]);
  expect(frames, hasLength(1));
  return RoomProximityEnvelope.decode(utf8.decode(frames.single));
}

class _RegistryFakeClassicBluetoothEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();

  /// Transport-plan traffic. The Bluetooth preference every linked session
  /// sends up front is kept apart in [preferences], so these read as the
  /// exchange each test drives.
  final writes = <Uint8List>[];
  final preferences = <RoomProximityEnvelope>[];

  @override
  Stream<Uint8List> get input => incoming.stream;

  @override
  Stream<String> get onPeerConnected => connected.stream;

  @override
  Stream<String> get onError => errors.stream;

  @override
  Stream<void> get onClosed => closed.stream;

  @override
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async => true;

  @override
  Future<void> startHosting({String name = 'tark'}) async {}

  @override
  Stream<BluetoothPeer> scanForHosts() => const Stream.empty();

  @override
  void cancelDiscovery() {}

  @override
  Future<void> write(Uint8List bytes) async {
    final frames = FrameReassembler().addBytes(Uint8List.fromList(bytes));
    final envelope = RoomProximityEnvelope.decode(utf8.decode(frames.single));
    if (envelope.kind == 'transportPreference') {
      preferences.add(envelope);
      return;
    }
    writes.add(Uint8List.fromList(bytes));
  }

  void addEnvelope(RoomProximityEnvelope envelope) {
    incoming.add(
      frameMessage(Uint8List.fromList(utf8.encode(envelope.encode()))),
    );
  }

  @override
  Future<void> dispose() async {
    await incoming.close();
    await connected.close();
    await errors.close();
    await closed.close();
  }
}
