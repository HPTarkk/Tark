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
import 'package:tark/feature/room/domain/service/room_invite_membership_receipt.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
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
        (member) => member.id.value == invitation.invitationId.substring(0, 24),
      );
      expect(joined, hasLength(1));
    },
  );

  test(
    'concurrent duplicate membership receipts confirm once and ACK twice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final repository = SharedPreferencesRoomRepository();
      final crypto = RoomMemberTransportIdentityCrypto();
      final issuerKey = await crypto.generateKeyPair();
      final memberKey = await crypto.generateKeyPair();
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
        requireMembershipReceipt: true,
        issueCertificate:
            ({
              required acceptedRoom,
              required memberId,
              required memberPublicKey,
            }) => crypto.issueCertificate(
              roomId: acceptedRoom.room.id,
              memberId: memberId,
              memberPublicKey: memberPublicKey,
              issuer: issuerKey,
            ),
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

      const requestId = 'dddddddddddddddddddddddddddddddd';
      final request = RoomInviteJoinRequest(
        requestId: requestId,
        invitation: invitation,
        displayName: 'Rider two',
        memberTransportPublicKey: memberKey.publicKey,
      );
      engine.addEnvelope(
        RoomProximityEnvelope(
          kind: 'joinRequest',
          roomId: invitation.roomId.value,
          requestId: requestId,
          joinEpoch: invitation.invitationId,
          payload: request.encode(),
        ),
      );
      await engine.waitForWrites(1);

      final grantEnvelope = _decodeWrite(engine.writes.single);
      final response = RoomInviteJoinResponse.decode(grantEnvelope.payload);
      expect(response.membershipReceiptRequired, isTrue);
      final receipt = await RoomInviteMembershipReceiptCrypto.sign(
        requestId: requestId,
        certificate: response.transportCertificate!,
        member: memberKey,
      );

      engine.writes.clear();
      final receiptEnvelope = RoomProximityEnvelope(
        kind: 'membershipReceipt',
        roomId: invitation.roomId.value,
        requestId: requestId,
        joinEpoch: invitation.invitationId,
        payload: receipt.encode(),
      );
      engine.addEnvelope(receiptEnvelope);
      engine.addEnvelope(receiptEnvelope);
      await engine.waitForWrites(2);

      final confirmations = engine.writes
          .map(_decodeWrite)
          .toList(growable: false);
      expect(
        confirmations.every((item) => item.kind == 'membershipConfirmed'),
        isTrue,
      );
      expect(confirmations[0].payload, confirmations[1].payload);
      final confirmation = jsonDecode(confirmations.first.payload);
      expect(confirmation, isA<Map<String, dynamic>>());
      expect((confirmation as Map<String, dynamic>)['ok'], isTrue);

      final saved = await repository.get(invitation.roomId);
      final joined = saved!.room.members.where(
        (member) => member.id.value == invitation.invitationId.substring(0, 24),
      );
      expect(joined, hasLength(1));
      expect(joined.single.pending, isFalse);
    },
  );

  test('QR-bound host challenge authenticates before join request', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Morning ride',
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
    final pair = _PairedCarrierEngines();
    final hostChannel = RoomProximityControlChannel(engine: pair.host);
    final joinerChannel = RoomProximityControlChannel(engine: pair.joiner);
    await hostChannel.host(rendezvousToken: invitation.invitationId);
    await joinerChannel.connect(rendezvousToken: invitation.invitationId);
    final issuer = RoomProximityJoinIssuerSession(
      channel: hostChannel,
      invitation: invitation,
      exchange: exchange,
      repository: repository,
    );
    final carrier = RoomProximityJoinCarrier(
      channel: joinerChannel,
      invitation: invitation,
    );
    addTearDown(() async {
      await carrier.dispose();
      await issuer.dispose();
      await joinerChannel.dispose();
      await hostChannel.dispose();
    });

    const requestId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final request = RoomInviteJoinRequest(
      requestId: requestId,
      invitation: invitation,
      displayName: 'Rider two',
    );

    final encoded = await carrier.exchange(request.encode());
    final response = RoomInviteJoinResponse.decode(encoded);

    expect(response.status, RoomInviteJoinResponseStatus.accepted);
    expect(response.requestId, requestId);
  });

  test('host proof from a different invite secret fails closed', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = SharedPreferencesRoomRepository();
    final room = await repository.create(
      name: 'Morning ride',
      localDisplayName: 'Owner',
    );
    final now = DateTime.now().toUtc();
    final invitation = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
    );
    final forged = RoomInvitation(
      version: invitation.version,
      roomId: invitation.roomId,
      invitationId: invitation.invitationId,
      secret: List.filled(64, 'f').join(),
      kind: invitation.kind,
      issuedAt: invitation.issuedAt,
      expiresAt: invitation.expiresAt,
      singleUse: invitation.singleUse,
      displayCode: invitation.displayCode,
      transportBootstrap: invitation.transportBootstrap,
    );
    final exchange = RoomInviteJoinExchange(
      acceptance: RoomInviteAcceptanceCoordinator(repository),
    );
    final pair = _PairedCarrierEngines();
    final hostChannel = RoomProximityControlChannel(engine: pair.host);
    final joinerChannel = RoomProximityControlChannel(engine: pair.joiner);
    final issuer = RoomProximityJoinIssuerSession(
      channel: hostChannel,
      invitation: invitation,
      exchange: exchange,
      repository: repository,
    );
    final carrier = RoomProximityJoinCarrier(
      channel: joinerChannel,
      invitation: forged,
    );
    addTearDown(() async {
      await carrier.dispose();
      await issuer.dispose();
      await joinerChannel.dispose();
      await hostChannel.dispose();
    });

    final request = RoomInviteJoinRequest(
      requestId: 'cccccccccccccccccccccccccccccccc',
      invitation: forged,
      displayName: 'Rider two',
    );

    await expectLater(
      carrier.exchange(request.encode()),
      throwsA(isA<StateError>()),
    );

    final saved = await repository.get(invitation.roomId);
    expect(saved!.room.members, hasLength(1));
  });
}

RoomProximityEnvelope _decodeWrite(Uint8List bytes) {
  final frames = FrameReassembler().addBytes(bytes);
  expect(frames, hasLength(1));
  return RoomProximityEnvelope.decode(utf8.decode(frames.single));
}

final class _PairedCarrierEngines {
  _PairedCarrierEngines() {
    host.peer = joiner;
    joiner.peer = host;
  }

  final host = _LinkedCarrierEngine();
  final joiner = _LinkedCarrierEngine();
}

final class _LinkedCarrierEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  _LinkedCarrierEngine? peer;

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
  Stream<BluetoothPeer> scanForHosts() => Stream.value(
    const BluetoothPeer(
      id: 'paired-peer',
      name: 'stale-name-is-irrelevant',
      isAppHost: true,
      rendezvousMatched: true,
    ),
  );

  @override
  void cancelDiscovery() {}

  @override
  Future<void> connectToHost(String address) async {
    connected.add(address);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    peer?.incoming.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> dispose() async {
    await incoming.close();
    await connected.close();
    await errors.close();
    await closed.close();
  }
}

final class _CarrierFakeEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final writes = <Uint8List>[];
  final twoWrites = Completer<void>();
  final writeCounts = StreamController<int>.broadcast();

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
    writeCounts.add(writes.length);
    if (writes.length == 2 && !twoWrites.isCompleted) twoWrites.complete();
  }

  Future<void> waitForWrites(int count) async {
    if (writes.length >= count) return;
    await writeCounts.stream
        .firstWhere((value) => value >= count)
        .timeout(const Duration(seconds: 2));
  }

  void addEnvelope(RoomProximityEnvelope envelope) {
    incoming.add(
      frameMessage(Uint8List.fromList(utf8.encode(envelope.encode()))),
    );
  }

  @override
  Future<void> dispose() async {
    await incoming.close();
    await writeCounts.close();
    await connected.close();
    await errors.close();
    await closed.close();
  }
}
