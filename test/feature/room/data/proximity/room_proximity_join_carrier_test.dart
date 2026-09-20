import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_join_carrier.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_acceptance_coordinator.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/bluetooth/length_prefixed_framer.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';

void main() {
  test(
    'concurrent duplicate join requests share one grant and one member',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repository = SharedPreferencesRoomRepository();
      final room = await repository.create(
        name: 'Night ride',
        localDisplayName: 'Owner',
      );
      final now = DateTime.now().toUtc();
      final invitation = await repository.issueInvite(
        room.room.id,
        kind: RoomInvitationKind.trustedMembership,
        now: now,
        ttl: const Duration(hours: 1),
      );
      final exchange = RoomInviteJoinExchange(
        acceptance: RoomInviteAcceptanceCoordinator(repository),
      );
      final engine = _CarrierFakeEngine();
      final channel = RoomProximityControlChannel(engine: engine);
      await channel.host(rendezvousToken: invitation.invitationId);
      final issuer = RoomProximityJoinIssuerSession(
        channel: channel,
        invitation: invitation,
        exchange: exchange,
        repository: repository,
      );
      addTearDown(() async {
        await issuer.dispose();
        await channel.dispose();
      });

      const requestId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final request = RoomInviteJoinRequest(
        requestId: requestId,
        invitation: invitation,
        displayName: 'Rider two',
      ).encode();
      final envelope = RoomProximityEnvelope(
        kind: 'joinRequest',
        roomId: invitation.roomId.value,
        requestId: requestId,
        joinEpoch: invitation.invitationId,
        payload: request,
      );

      engine.addEnvelope(envelope);
      engine.addEnvelope(envelope);
      await engine.twoWrites.future.timeout(const Duration(seconds: 2));

      expect(engine.writes, hasLength(2));
      final responses = engine.writes.map(_decodeWrite).toList(growable: false);
      expect(responses.every((item) => item.kind == 'joinGrant'), isTrue);
      expect(responses[0].payload, responses[1].payload);
      expect(
        RoomInviteJoinResponse.decode(responses[0].payload).status,
        RoomInviteJoinResponseStatus.accepted,
      );

      final saved = await repository.get(invitation.roomId);
      final joined = saved!.room.members.where(
        (member) =>
            member.id.value == invitation.invitationId.substring(0, 24),
      );
      expect(joined, hasLength(1));
    },
  );
}

RoomProximityEnvelope _decodeWrite(Uint8List bytes) {
  final frames = FrameReassembler().addBytes(bytes);
  expect(frames, hasLength(1));
  return RoomProximityEnvelope.decode(utf8.decode(frames.single));
}

final class _CarrierFakeEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final writes = <Uint8List>[];
  final twoWrites = Completer<void>();

  @override
  Future<bool> get isEnabled async => true;

  @override
  Stream<Uint8List> get input => incoming.stream;

  @override
  Stream<String> get onPeerConnected => connected.stream;

  @override
  Stream<String> get onError => errors.stream;

  @override
  Stream<void> get onClosed => closed.stream;

  @override
  Future<void> startHosting({String name = 'tark'}) async {}

  @override
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async => true;

  @override
  Stream<BluetoothPeer> scanForHosts() => const Stream.empty();

  @override
  void cancelDiscovery() {}

  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(Uint8List.fromList(bytes));
    if (writes.length == 2 && !twoWrites.isCompleted) twoWrites.complete();
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
