import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';

/// A face seen on a live ride is remembered on the Room, so the lobby shows it
/// the next time instead of falling back to an initial for everybody.
void main() {
  late SharedPreferencesRoomRepository host;
  final at = DateTime.utc(2099, 9, 3);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    host = SharedPreferencesRoomRepository();
  });

  Future<(SavedRoom, RoomMemberId)> addRider(SavedRoom room) async {
    final invite = await host.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: at,
      ttl: const Duration(hours: 12),
    );
    final verified = await host.verifyAndRedeemInvite(invite, now: at);
    final next = await host.acceptVerifiedInvite(
      verified!,
      displayName: 'Rider two',
      acceptedAt: at,
      pending: false,
    );
    return (next, RoomMemberId(invite.invitationId.substring(0, 24)));
  }

  test('a remembered avatar survives a reload', () async {
    final room = await host.create(name: 'Night ride', localDisplayName: 'Me');
    final (withRider, riderId) = await addRider(room);

    await host.updateMember(withRider.room.id, riderId, avatarId: 7);

    final reloaded = await SharedPreferencesRoomRepository().get(room.room.id);
    final rider = reloaded!.room.members.singleWhere((m) => m.id == riderId);
    expect(rider.avatarId, 7);
    final me = reloaded.room.members.singleWhere(
      (m) => m.id == reloaded.membership.localMemberId,
    );
    expect(me.avatarId, isNull, reason: 'never seen, so no face');
  });

  test('the same avatar again is not a write', () async {
    final room = await host.create(name: 'Night ride', localDisplayName: 'Me');
    final (withRider, riderId) = await addRider(room);
    final first = await host.updateMember(
      withRider.room.id,
      riderId,
      avatarId: 3,
    );
    final again = await host.updateMember(
      withRider.room.id,
      riderId,
      avatarId: 3,
    );
    expect(again.room.updatedAt, first.room.updatedAt);
  });

  test('rejoining keeps the faces this phone already knew', () async {
    final room = await host.create(name: 'Night ride', localDisplayName: 'Me');
    final (issued, joinerId) = await addRider(room);
    final snapshot = RoomAcceptedJoinSnapshot.decode(
      RoomAcceptedJoinSnapshot.fromSavedRoom(
        issued,
        acceptedMemberId: joinerId,
      ).encode(),
    );

    SharedPreferences.setMockInitialValues({});
    final joiner = SharedPreferencesRoomRepository();
    final mine = await joiner.importAcceptedJoin(
      snapshot,
      localMemberId: joinerId,
    );
    final hostId = mine.room.members.firstWhere((m) => m.id != joinerId).id;
    await joiner.updateMember(mine.room.id, hostId, avatarId: 5);

    final again = await joiner.importAcceptedJoin(
      snapshot,
      localMemberId: joinerId,
    );
    expect(again.room.members.singleWhere((m) => m.id == hostId).avatarId, 5);
  });
}
