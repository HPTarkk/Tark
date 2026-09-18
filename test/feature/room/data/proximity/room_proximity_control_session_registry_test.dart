import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_control_session_registry.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_join_carrier.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
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
          .waitForHotspot(roomId: roomId, transportEpoch: 7);
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
}

RoomProximityEnvelope _decodeSingleWrite(
  _RegistryFakeClassicBluetoothEngine engine,
) {
  expect(engine.writes, hasLength(1));
  final frames = FrameReassembler().addBytes(engine.writes.single);
  expect(frames, hasLength(1));
  return RoomProximityEnvelope.decode(utf8.decode(frames.single));
}

class _RegistryFakeClassicBluetoothEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final writes = <Uint8List>[];

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
