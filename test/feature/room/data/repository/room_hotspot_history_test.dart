import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/feature/room/data/repository/room_hotspot_history.dart';
import 'package:tark/feature/room/domain/entity/room.dart';

void main() {
  const roomId = RoomId('0123456789abcdef0123456789abcdef');
  final creator = RoomMemberId('111111111111111111111111');
  final rider = RoomMemberId('222222222222222222222222');
  final t0 = DateTime.utc(2026, 9, 5, 7);

  SavedRoom room({RoomMemberId? local, bool riderRemoved = false}) => SavedRoom(
    room: Room(
      id: roomId,
      name: 'Night ride',
      createdAt: t0,
      updatedAt: t0,
      members: [
        // Listed out of join order on purpose: election must not depend on it.
        RoomMember(
          id: rider,
          displayName: 'Rider two',
          joinedAt: t0.add(const Duration(minutes: 1)),
          removedAt: riderRemoved ? t0.add(const Duration(hours: 1)) : null,
        ),
        RoomMember(id: creator, displayName: 'Rider one', joinedAt: t0),
      ],
    ),
    membership: RoomMembership(
      localMemberId: local ?? creator,
      canManageInvites: true,
    ),
  );

  test('with no history the creator shows the code, on every phone', () async {
    SharedPreferences.setMockInitialValues({});
    final history = RoomHotspotHistory();
    expect(await history.electHost(room(local: creator)), creator);
    expect(await history.electHost(room(local: rider)), creator);
  });

  test('the last hotspot host is elected again', () async {
    SharedPreferences.setMockInitialValues({});
    final history = RoomHotspotHistory();
    await history.recordHost(roomId, rider);
    expect(await history.electHost(room()), rider);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(
        '${SettingsKeys.roomLastHotspotHostPrefix}${roomId.value}',
      ),
      rider.value,
    );
  });

  test('a last host who left the Room falls back to the creator', () async {
    SharedPreferences.setMockInitialValues({});
    final history = RoomHotspotHistory();
    await history.recordHost(roomId, rider);
    expect(await history.electHost(room(riderRemoved: true)), creator);
  });
}
