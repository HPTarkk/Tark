import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';

void main() {
  late SharedPreferencesRoomRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  test('creates multiple generic rooms and keeps duplicate names independent', () async {
    final first = await repository.create(name: 'Weekend Ride', localDisplayName: 'A');
    final second = await repository.create(name: 'Weekend Ride', localDisplayName: 'A');

    expect(first.room.id, isNot(second.room.id));
    expect((await repository.list()).map((item) => item.room.id), containsAll([first.room.id, second.room.id]));
  });

  test('room survives repository recreation and explicit selection', () async {
    final created = await repository.create(name: 'North', localDisplayName: 'Rider');
    await repository.select(created.room.id);

    final reopened = SharedPreferencesRoomRepository();

    expect((await reopened.get(created.room.id))?.room.name, 'North');
    expect(await reopened.selectedRoomId(), created.room.id);
  });

  test('archive hides by default without deleting membership', () async {
    final created = await repository.create(name: 'Old Ride', localDisplayName: 'A');
    await repository.setArchived(created.room.id, true);

    expect(await repository.list(), isEmpty);
    final withArchived = await repository.list(includeArchived: true);
    expect(withArchived.single.room.archived, isTrue);
    expect(withArchived.single.membership.active, isTrue);
  });

  test('leave deactivates durable membership and clears current selection', () async {
    final created = await repository.create(name: 'Crew', localDisplayName: 'A');
    await repository.select(created.room.id);

    final left = await repository.leave(created.room.id);

    expect(left.membership.active, isFalse);
    expect(left.room.members.single.isActive, isFalse);
    expect(await repository.selectedRoomId(), isNull);
  });

  test('one corrupt room is skipped without losing unrelated rooms', () async {
    final good = await repository.create(name: 'Good', localDisplayName: 'A');
    final corrupt = await repository.create(name: 'Bad', localDisplayName: 'A');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rooms.v1.room.${corrupt.room.id.value}', '{not json');

    final rooms = await repository.list(includeArchived: true);

    expect(rooms.map((item) => item.room.id), [good.room.id]);
    expect(await repository.get(corrupt.room.id), isNull);
  });

  test('unsupported room schema fails closed while other schemas survive', () async {
    final good = await repository.create(name: 'Good', localDisplayName: 'A');
    final old = await repository.create(name: 'Old', localDisplayName: 'A');
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonDecode(prefs.getString('rooms.v1.room.${old.room.id.value}')!) as Map<String, dynamic>;
    raw['schemaVersion'] = 999;
    await prefs.setString('rooms.v1.room.${old.room.id.value}', jsonEncode(raw));

    expect((await repository.list(includeArchived: true)).map((item) => item.room.id), [good.room.id]);
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
