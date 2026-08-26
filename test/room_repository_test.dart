import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';

void main() {
  late SharedPreferencesRoomRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  test(
    'creates multiple generic rooms and keeps duplicate names independent',
    () async {
      final first = await repository.create(
        name: 'Weekend Ride',
        localDisplayName: 'A',
      );
      final second = await repository.create(
        name: 'Weekend Ride',
        localDisplayName: 'A',
      );

      expect(first.room.id, isNot(second.room.id));
      expect(
        (await repository.list()).map((item) => item.room.id),
        containsAll([first.room.id, second.room.id]),
      );
    },
  );

  test('room survives repository recreation and explicit selection', () async {
    final created = await repository.create(
      name: 'North',
      localDisplayName: 'Rider',
    );
    await repository.select(created.room.id);

    final reopened = SharedPreferencesRoomRepository();

    expect((await reopened.get(created.room.id))?.room.name, 'North');
    expect(await reopened.selectedRoomId(), created.room.id);
  });

  test('archive hides by default without deleting membership', () async {
    final created = await repository.create(
      name: 'Old Ride',
      localDisplayName: 'A',
    );
    await repository.setArchived(created.room.id, true);

    expect(await repository.list(), isEmpty);
    final withArchived = await repository.list(includeArchived: true);
    expect(withArchived.single.room.archived, isTrue);
    expect(withArchived.single.membership.active, isTrue);
  });

  test(
    'leave deactivates durable membership and clears current selection',
    () async {
      final created = await repository.create(
        name: 'Crew',
        localDisplayName: 'A',
      );
      await repository.select(created.room.id);

      final left = await repository.leave(created.room.id);

      expect(left.membership.active, isFalse);
      expect(left.room.members.single.isActive, isFalse);
      expect(await repository.selectedRoomId(), isNull);
    },
  );

  test('one corrupt room is skipped without losing unrelated rooms', () async {
    final good = await repository.create(name: 'Good', localDisplayName: 'A');
    final corrupt = await repository.create(name: 'Bad', localDisplayName: 'A');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'rooms.v1.room.${corrupt.room.id.value}',
      '{not json',
    );

    final rooms = await repository.list(includeArchived: true);

    expect(rooms.map((item) => item.room.id), [good.room.id]);
    expect(await repository.get(corrupt.room.id), isNull);
  });

  test(
    'unsupported room schema fails closed while other schemas survive',
    () async {
      final good = await repository.create(name: 'Good', localDisplayName: 'A');
      final old = await repository.create(name: 'Old', localDisplayName: 'A');
      final prefs = await SharedPreferences.getInstance();
      final raw =
          jsonDecode(prefs.getString('rooms.v1.room.${old.room.id.value}')!)
              as Map<String, dynamic>;
      raw['schemaVersion'] = 999;
      await prefs.setString(
        'rooms.v1.room.${old.room.id.value}',
        jsonEncode(raw),
      );

      expect(
        (await repository.list(
          includeArchived: true,
        )).map((item) => item.room.id),
        [good.room.id],
      );
    },
  );

  test('verified accepted join imports truthful durable Room state', () async {
    final createdAt = DateTime.utc(2026, 8, 20, 8);
    final updatedAt = DateTime.utc(2026, 8, 26, 15);
    const roomId = RoomId('0123456789abcdef0123456789abcdef');
    const ownerId = RoomMemberId('111111111111111111111111');
    const localId = RoomMemberId('222222222222222222222222');
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: 'Night riders',
      roomCreatedAt: createdAt,
      roomUpdatedAt: updatedAt,
      members: [
        RoomAcceptedJoinMember(
          memberId: ownerId,
          displayName: 'Owner',
          joinedAt: createdAt,
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: localId,
          displayName: 'Joined rider',
          joinedAt: updatedAt,
          kind: RoomMemberKind.member,
        ),
      ],
    );

    final imported = await repository.importAcceptedJoin(
      snapshot,
      localMemberId: localId,
    );
    await repository.select(roomId);
    final reopened = SharedPreferencesRoomRepository();
    final persisted = await reopened.get(roomId);

    expect(imported.room.id, roomId);
    expect(imported.room.name, 'Night riders');
    expect(imported.room.createdAt, createdAt);
    expect(imported.room.updatedAt, updatedAt);
    expect(imported.room.members, hasLength(2));
    expect(imported.room.members.first.joinedAt, createdAt);
    expect(imported.room.members.last.joinedAt, updatedAt);
    expect(imported.membership.localMemberId, localId);
    expect(imported.membership.active, isTrue);
    expect(imported.membership.canManageInvites, isFalse);
    expect(persisted?.room.name, 'Night riders');
    expect(persisted?.membership.localMemberId, localId);
    expect(await reopened.selectedRoomId(), roomId);
  });

  test(
    'accepted join import is idempotent for the same local member',
    () async {
      final now = DateTime.utc(2026, 8, 26, 15);
      const roomId = RoomId('0123456789abcdef0123456789abcdef');
      const localId = RoomMemberId('222222222222222222222222');
      final snapshot = RoomAcceptedJoinSnapshot(
        roomId: roomId,
        roomName: 'Night riders',
        roomCreatedAt: now,
        roomUpdatedAt: now,
        members: [
          RoomAcceptedJoinMember(
            memberId: localId,
            displayName: 'Joined rider',
            joinedAt: now,
            kind: RoomMemberKind.member,
          ),
        ],
      );

      await repository.importAcceptedJoin(snapshot, localMemberId: localId);
      await repository.importAcceptedJoin(snapshot, localMemberId: localId);

      final rooms = await repository.list(includeArchived: true);
      expect(rooms, hasLength(1));
      expect(rooms.single.room.members, hasLength(1));
      expect(rooms.single.membership.localMemberId, localId);
    },
  );

  test('accepted join import fails when local member is absent', () async {
    final now = DateTime.utc(2026, 8, 26, 15);
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: const RoomId('0123456789abcdef0123456789abcdef'),
      roomName: 'Night riders',
      roomCreatedAt: now,
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: const RoomMemberId('111111111111111111111111'),
          displayName: 'Owner',
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
      ],
    );

    await expectLater(
      repository.importAcceptedJoin(
        snapshot,
        localMemberId: const RoomMemberId('222222222222222222222222'),
      ),
      throwsStateError,
    );
    expect(await repository.list(includeArchived: true), isEmpty);
  });

  test('accepted join cannot overwrite another local membership', () async {
    final existing = await repository.create(
      name: 'Existing local room',
      localDisplayName: 'Local owner',
    );
    final now = existing.room.createdAt.add(const Duration(seconds: 1));
    const otherLocalId = RoomMemberId('222222222222222222222222');
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: existing.room.id,
      roomName: 'Remote replacement',
      roomCreatedAt: existing.room.createdAt,
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: otherLocalId,
          displayName: 'Other local',
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
      ],
    );

    await expectLater(
      repository.importAcceptedJoin(snapshot, localMemberId: otherLocalId),
      throwsStateError,
    );

    final persisted = await repository.get(existing.room.id);
    expect(persisted?.room.name, 'Existing local room');
    expect(
      persisted?.membership.localMemberId,
      existing.membership.localMemberId,
    );
  });

  test('generic domain has no two-person limit', () {
    Room roomWith(int count) {
      final now = DateTime.utc(2026, 8, 25);
      return Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Group',
        createdAt: now,
        updatedAt: now,
        members: List.generate(
          count,
          (index) => RoomMember(
            id: RoomMemberId('member-$index'),
            displayName: 'Rider $index',
            joinedAt: now,
          ),
        ),
      );
    }

    expect(roomWith(2).members, hasLength(2));
    expect(roomWith(3).members, hasLength(3));
    expect(roomWith(5).members, hasLength(5));
  });

  test('RoomId rejects short channel codes and transport identifiers', () {
    expect(RoomId.parse('A83F21'), isNull);
    expect(RoomId.parse('192.168.43.1'), isNull);
    expect(RoomId.parse('AndroidShare_1234'), isNull);
    expect(RoomId.parse('0123456789abcdef0123456789abcdef'), isNotNull);
  });
}
