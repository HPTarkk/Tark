import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';

void main() {
  final roomId = RoomId.parse('0123456789abcdef0123456789abcdef')!;
  final now = DateTime.utc(2026, 8, 26, 15);
  const acceptedId = RoomMemberId('222222222222222222222222');

  SavedRoom savedRoom() => SavedRoom(
    room: Room(
      id: roomId,
      name: ' Night riders ',
      createdAt: now.subtract(const Duration(days: 2)),
      updatedAt: now,
      members: [
        RoomMember(
          id: const RoomMemberId('111111111111111111111111'),
          displayName: 'Owner',
          joinedAt: now.subtract(const Duration(days: 2)),
        ),
        RoomMember(
          id: acceptedId,
          displayName: 'Rider three',
          joinedAt: now,
        ),
        RoomMember(
          id: const RoomMemberId('333333333333333333333333'),
          displayName: 'Old rider',
          joinedAt: now.subtract(const Duration(days: 1)),
          removedAt: now,
        ),
      ],
    ),
    membership: const RoomMembership(
      localMemberId: RoomMemberId('111111111111111111111111'),
      canManageInvites: true,
    ),
  );

  test('round trips only durable active Room state and timestamps', () {
    final snapshot = RoomAcceptedJoinSnapshot.fromSavedRoom(
      savedRoom(),
      acceptedMemberId: acceptedId,
    );
    final decoded = RoomAcceptedJoinSnapshot.decode(snapshot.encode());

    expect(decoded.roomId, roomId);
    expect(decoded.roomName, 'Night riders');
    expect(decoded.roomCreatedAt, now.subtract(const Duration(days: 2)));
    expect(decoded.roomUpdatedAt, now);
    expect(decoded.members, hasLength(2));
    expect(decoded.members.first.memberId.value, '111111111111111111111111');
    expect(decoded.members.first.joinedAt, now.subtract(const Duration(days: 2)));
    expect(decoded.members.last.displayName, 'Rider three');
    expect(decoded.members.last.joinedAt, now);
  });

  test('accepted member survives bounded large roster', () {
    final members = <RoomMember>[
      for (var i = 0; i < 12; i++)
        RoomMember(
          id: RoomMemberId(i.toRadixString(16).padLeft(24, '0')),
          displayName: 'Rider $i',
          joinedAt: now,
        ),
      RoomMember(
        id: acceptedId,
        displayName: 'Accepted rider',
        joinedAt: now,
      ),
    ];
    final saved = SavedRoom(
      room: Room(
        id: roomId,
        name: 'Large ride',
        createdAt: now,
        updatedAt: now,
        members: members,
      ),
      membership: RoomMembership(
        localMemberId: members.first.id,
        canManageInvites: true,
      ),
    );

    final snapshot = RoomAcceptedJoinSnapshot.fromSavedRoom(
      saved,
      acceptedMemberId: acceptedId,
    );

    expect(snapshot.members, hasLength(RoomAcceptedJoinSnapshot.maxMembers));
    expect(
      snapshot.members.map((member) => member.memberId),
      contains(acceptedId),
    );
  });

  test('missing accepted member fails closed', () {
    expect(
      () => RoomAcceptedJoinSnapshot.fromSavedRoom(
        savedRoom(),
        acceptedMemberId: const RoomMemberId('ffffffffffffffffffffffff'),
      ),
      throwsStateError,
    );
  });

  test('encoded snapshot contains no transport or invite secret fields', () {
    final encoded = RoomAcceptedJoinSnapshot.fromSavedRoom(
      savedRoom(),
      acceptedMemberId: acceptedId,
    ).encode();
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
        roomCreatedAt: now,
        roomUpdatedAt: now,
        members: [
          RoomAcceptedJoinMember(
            memberId: const RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
            displayName: 'A',
            joinedAt: now,
            kind: RoomMemberKind.member,
          ),
          RoomAcceptedJoinMember(
            memberId: const RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
            displayName: 'B',
            joinedAt: now,
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
