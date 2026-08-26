import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_client.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';

void main() {
  const client = RoomInviteJoinClient();
  final now = DateTime.utc(2026, 8, 26, 15);
  final roomId = RoomId.parse('0123456789abcdef0123456789abcdef')!;

  RoomInviteJoinRequest request() {
    final invite = generateRoomInvitation(
      roomId: roomId,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 1),
      random: Random(9),
    );
    return RoomInviteJoinRequest(
      requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      invitation: invite,
      displayName: '  Rider three  ',
    );
  }

  RoomMemberId expectedMember(RoomInviteJoinRequest value) =>
      RoomMemberId(value.invitation.invitationId.substring(0, 24));

  RoomAcceptedJoinSnapshot snapshot(
    RoomInviteJoinRequest value, {
    RoomId? forRoom,
    RoomMemberId? member,
  }) => RoomAcceptedJoinSnapshot(
    roomId: forRoom ?? value.invitation.roomId,
    roomName: 'Night ride',
    members: [
      RoomAcceptedJoinMember(
        memberId: member ?? expectedMember(value),
        displayName: 'Rider three',
        kind: RoomMemberKind.member,
      ),
    ],
  );

  test('accepts only the correlated issuer grant and durable snapshot', () {
    final value = request();
    final response = RoomInviteJoinResponse.accepted(
      requestId: value.requestId,
      roomId: value.invitation.roomId,
      memberId: expectedMember(value),
      snapshot: snapshot(value),
    );
    final grant = client.verifyAcceptedResponse(
      request: value,
      encodedResponse: response.encode(),
    );
    expect(grant, isNotNull);
    expect(grant!.roomId, roomId);
    expect(grant.memberId, expectedMember(value));
    expect(grant.displayName, 'Rider three');
    expect(grant.snapshot.roomName, 'Night ride');
  });

  test('legacy accepted response without snapshot is not importable', () {
    final value = request();
    final response = RoomInviteJoinResponse.accepted(
      requestId: value.requestId,
      roomId: value.invitation.roomId,
      memberId: expectedMember(value),
    );

    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: response.encode(),
      ),
      isNull,
    );
  });

  test('rejects accepted response for another outstanding request', () {
    final value = request();
    final response = RoomInviteJoinResponse.accepted(
      requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      roomId: value.invitation.roomId,
      memberId: expectedMember(value),
      snapshot: snapshot(value),
    );
    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: response.encode(),
      ),
      isNull,
    );
  });

  test('rejects cross-room or forged member identity', () {
    final value = request();
    final otherRoom = RoomId.parse('fedcba9876543210fedcba9876543210')!;
    final crossRoom = RoomInviteJoinResponse.accepted(
      requestId: value.requestId,
      roomId: otherRoom,
      memberId: expectedMember(value),
      snapshot: snapshot(value, forRoom: otherRoom),
    );
    const forged = RoomMemberId('ffffffffffffffffffffffff');
    final forgedMember = RoomInviteJoinResponse.accepted(
      requestId: value.requestId,
      roomId: value.invitation.roomId,
      memberId: forged,
      snapshot: snapshot(value, member: forged),
    );
    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: crossRoom.encode(),
      ),
      isNull,
    );
    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: forgedMember.encode(),
      ),
      isNull,
    );
  });

  test('accepted identity without matching snapshot member fails closed', () {
    final value = request();
    final response = RoomInviteJoinResponse.accepted(
      requestId: value.requestId,
      roomId: value.invitation.roomId,
      memberId: expectedMember(value),
      snapshot: snapshot(
        value,
        member: const RoomMemberId('eeeeeeeeeeeeeeeeeeeeeeee'),
      ),
    );

    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: response.encode(),
      ),
      isNull,
    );
  });

  test('rejection response never becomes a local join grant', () {
    final value = request();
    final response = RoomInviteJoinResponse.rejected(
      requestId: value.requestId,
    );
    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: response.encode(),
      ),
      isNull,
    );
  });

  test('malformed response fails closed', () {
    final value = request();
    expect(
      client.verifyAcceptedResponse(
        request: value,
        encodedResponse: 'not-a-response',
      ),
      isNull,
    );
  });
}
