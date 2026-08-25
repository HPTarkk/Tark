import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_session_factory.dart';

void main() {
  final now = DateTime.utc(2026, 8, 26);
  const roomId = RoomId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  const localId = RoomMemberId('111111111111111111111111');
  const peerId = RoomMemberId('222222222222222222222222');

  SavedRoom saved({
    bool archived = false,
    bool membershipActive = true,
    bool includeLocalMember = true,
    bool removePeer = false,
  }) {
    return SavedRoom(
      room: Room(
        id: roomId,
        name: 'Riders',
        createdAt: now,
        updatedAt: now,
        archived: archived,
        members: [
          if (includeLocalMember)
            RoomMember(id: localId, displayName: 'Me', joinedAt: now),
          RoomMember(
            id: peerId,
            displayName: 'Peer',
            joinedAt: now,
            removedAt: removePeer ? now : null,
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localId,
        canManageInvites: true,
        active: membershipActive,
      ),
    );
  }

  test('uses durable Room and active member identities unchanged', () async {
    final runtime = RoomSessionFactory.open(
      saved(removePeer: true),
      sessionId: 'session-42',
    );

    expect(runtime, isNotNull);
    expect(runtime!.state.roomId, roomId.value);
    expect(runtime.state.localMemberId, localId.value);
    expect(runtime.state.memberIds, {localId.value});
    expect(runtime.state.sessionId, 'session-42');
    await runtime.leave();
  });

  test('archived room cannot start a live logical session', () {
    expect(
      RoomSessionFactory.open(saved(archived: true), sessionId: 'session-1'),
      isNull,
    );
  });

  test('inactive local membership cannot start a session', () {
    expect(
      RoomSessionFactory.open(
        saved(membershipActive: false),
        sessionId: 'session-1',
      ),
      isNull,
    );
  });

  test('membership without matching active member fails closed', () {
    expect(
      RoomSessionFactory.open(
        saved(includeLocalMember: false),
        sessionId: 'session-1',
      ),
      isNull,
    );
  });

  test('blank session identity fails closed', () {
    expect(RoomSessionFactory.open(saved(), sessionId: '   '), isNull);
  });
}
