import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_acceptance_coordinator.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_invite_membership_receipt.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  late SharedPreferencesRoomRepository repository;
  late RoomInviteJoinExchange exchange;
  late RoomInvitation invitation;
  late RoomMemberTransportIdentityCrypto crypto;
  late RoomMemberTransportKeyPair issuer;
  final now = DateTime.utc(2026, 9, 6, 19);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    crypto = RoomMemberTransportIdentityCrypto();
    issuer = await crypto.generateKeyPair();
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Owner',
    );
    invitation = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
    );
    exchange = RoomInviteJoinExchange(
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
            issuer: issuer,
          ),
    );
  });

  test('signed receipt confirms the same member on both phones', () async {
    final result = await RoomInviteJoinOrchestrator(random: Random(7)).join(
      invitation: invitation,
      displayName: 'Rider',
      requestId: '0123456789abcdef0123456789abcdef',
      carrier: _ReceiptCarrier(exchange, now),
    );

    expect(result.status, RoomInviteJoinAttemptStatus.accepted);
    final saved = await repository.get(invitation.roomId);
    final joined = saved!.room.members.singleWhere(
      (member) => member.id.value == invitation.invitationId.substring(0, 24),
    );
    expect(joined.pending, isFalse);
    expect(joined.displayName, 'Rider');
  });

  test(
    'response without a receipt leaves the issuer seat unconfirmed',
    () async {
      final member = await crypto.generateKeyPair();
      final response = await exchange.handleEncodedRequest(
        RoomInviteJoinRequest(
          requestId: 'fedcba9876543210fedcba9876543210',
          invitation: invitation,
          displayName: 'Rider',
          memberTransportPublicKey: member.publicKey,
        ).encode(),
        now: now,
      );

      expect(
        RoomInviteJoinResponse.decode(response).membershipReceiptRequired,
        isTrue,
      );
      final saved = await repository.get(invitation.roomId);
      expect(saved!.room.members.last.pending, isTrue);
    },
  );

  test('forged receipt cannot confirm a held seat', () async {
    final member = await crypto.generateKeyPair();
    final response = RoomInviteJoinResponse.decode(
      await exchange.handleEncodedRequest(
        RoomInviteJoinRequest(
          requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          invitation: invitation,
          displayName: 'Rider',
          memberTransportPublicKey: member.publicKey,
        ).encode(),
        now: now,
      ),
    );
    final attacker = await crypto.generateKeyPair();
    final receipt = await _signWithWrongKey(
      response: response,
      requestId: response.requestId,
      attacker: attacker,
    );

    expect(await exchange.handleEncodedReceipt(receipt), isFalse);
    expect(
      (await repository.get(invitation.roomId))!.room.members.last.pending,
      isTrue,
    );
  });
}

final class _ReceiptCarrier implements RoomInviteJoinReceiptCarrier {
  const _ReceiptCarrier(this._issuer, this.now);

  final RoomInviteJoinExchange _issuer;
  final DateTime now;

  @override
  Future<String> exchange(String encodedRequest) =>
      _issuer.handleEncodedRequest(encodedRequest, now: now);

  @override
  Future<bool> submitMembershipReceipt(String encodedReceipt) =>
      _issuer.handleEncodedReceipt(encodedReceipt);
}

Future<String> _signWithWrongKey({
  required RoomInviteJoinResponse response,
  required String requestId,
  required RoomMemberTransportKeyPair attacker,
}) async {
  final certificate = response.transportCertificate!;
  final forged = RoomMemberTransportCertificate(
    roomId: certificate.roomId,
    memberId: certificate.memberId,
    memberPublicKey: attacker.publicKey,
    issuerPublicKey: certificate.issuerPublicKey,
    issuerSignature: certificate.issuerSignature,
  );
  return (await RoomInviteMembershipReceiptCrypto.sign(
    requestId: requestId,
    certificate: forged,
    member: attacker,
  )).encode();
}
