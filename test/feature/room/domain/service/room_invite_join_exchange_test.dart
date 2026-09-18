import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';

void main() {
  final roomId = RoomId.parse('0123456789abcdef0123456789abcdef')!;
  final now = DateTime.utc(2026, 8, 26, 12);

  RoomInvitation invite() => generateRoomInvitation(
    roomId: roomId,
    kind: RoomInvitationKind.trustedMembership,
    now: now,
    ttl: const Duration(hours: 1),
    random: Random(7),
  );

  test('join request round-trips bearer capability without transport data', () {
    final request = RoomInviteJoinRequest(
      requestId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      invitation: invite(),
      displayName: '  Rider A  ',
    );

    final decoded = RoomInviteJoinRequest.decode(request.encode());

    expect(decoded.requestId, request.requestId);
    expect(decoded.displayName, 'Rider A');
    expect(decoded.invitation.roomId, roomId);
    expect(decoded.invitation.secret, request.invitation.secret);
    expect(decoded.invitation.transportBootstrap, isNull);
  });

  test(
    'join request rejects malformed identity and oversized display name',
    () {
      expect(
        () => RoomInviteJoinRequest(
          requestId: 'not-a-request-id',
          invitation: invite(),
          displayName: 'Rider',
        ).encode(),
        throwsFormatException,
      );
      expect(
        () => RoomInviteJoinRequest(
          requestId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          invitation: invite(),
          displayName: 'x' * 81,
        ).encode(),
        throwsFormatException,
      );
    },
  );

  test('accepted response round-trips only durable room/member identity', () {
    const memberId = RoomMemberId('1234567890abcdef12345678');
    final response = RoomInviteJoinResponse.accepted(
      requestId: 'cccccccccccccccccccccccccccccccc',
      roomId: roomId,
      memberId: memberId,
    );

    final decoded = RoomInviteJoinResponse.decode(response.encode());

    expect(decoded.status, RoomInviteJoinResponseStatus.accepted);
    expect(decoded.requestId, response.requestId);
    expect(decoded.roomId, roomId);
    expect(decoded.memberId, memberId);
  });

  test('rejected response cannot smuggle durable identity', () {
    final response = RoomInviteJoinResponse.rejected(
      requestId: 'dddddddddddddddddddddddddddddddd',
    );
    final encoded = response.encode();
    final decoded = RoomInviteJoinResponse.decode(encoded);

    expect(decoded.status, RoomInviteJoinResponseStatus.rejected);
    expect(decoded.roomId, isNull);
    expect(decoded.memberId, isNull);
  });

  test('decoder fails closed on unsupported or malformed payload', () {
    expect(
      () => RoomInviteJoinRequest.decode('not-base64-json'),
      throwsFormatException,
    );
    expect(
      () => RoomInviteJoinResponse.decode('not-base64-json'),
      throwsFormatException,
    );
  });
}
