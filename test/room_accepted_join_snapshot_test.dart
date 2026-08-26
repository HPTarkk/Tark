import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_accepted_join_snapshot.dart';

void main() {
  final roomId = RoomId.parse('0123456789abcdef0123456789abcdef')!;
  final now = DateTime.utc(2026, 8, 26, 15);

  SavedRoom savedRoom() => SavedRoom(
    room: Room(
      id: roomId,
      name: ' Night riders ',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(
          id: const RoomMemberId('111111111111111111111111'),
          displayName: 'Owner',
          joinedAt: now,
        ),
        RoomMember(
          id: const RoomMemberId('222222222222222222222222'),
          displayName: 'Rider three',
          joinedAt: now,
        ),
        RoomMember(
          id: const RoomMemberId('333333333333333333333333'),
          displayName: 'Old rider',
          joinedAt: now,
          removedAt: now,
        ),
      ],
    ),
    membership: const RoomMembership(
      localMemberId: RoomMemberId('111111111111111111111111'),
      canManageInvites: true,
    ),
  );

  test('round trips only durable active Room state', () {
    final snapshot = RoomAcceptedJoinSnapshot.fromSavedRoom(savedRoom());
    final decoded = RoomAcceptedJoinSnapshot.decode(snapshot.encode());

    expect(decoded.roomId, roomId);
    expect(decoded.roomName, 'Night riders');
    expect(decoded.members, hasLength(2));
    expect(decoded.members.first.memberId.value, '111111111111111111111111');
    expect(decoded.members.last.displayName, 'Rider three');
  });

  test('encoded snapshot contains no transport or invite secret fields', () {
    final encoded = RoomAcceptedJoinSnapshot.fromSavedRoom(savedRoom()).encode();
    final decoded = RoomAcceptedJoinSnapshot.decode(encoded);

    expect(decoded.roomName, 'Night riders');
    expect(encoded, isNot(contains('ssid')));
    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('secret')));
    expect(encoded, isNot(contains('transport')));
  });

  test('duplicate member identity fails closed', () {
    expect(
      () => RoomAcceptedJoinSnapshot(
        roomId: roomId,
        roomName: 'Room',
        members: const [
          RoomAcceptedJoinMember(
            memberId: RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
            displayName: 'A',
            kind: RoomMemberKind.member,
          ),
          RoomAcceptedJoinMember(
            memberId: RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
            displayName: 'B',
            kind: RoomMemberKind.member,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('malformed and oversized snapshots fail closed', () {
    expect(
      () => RoomAcceptedJoinSnapshot.decode('not-a-snapshot'),
      throwsFormatException,
    );
    expect(
      () => RoomAcceptedJoinSnapshot.decode(
        'a' * (RoomAcceptedJoinSnapshot.maxEncodedLength + 1),
      ),
      throwsFormatException,
    );
  });
}
