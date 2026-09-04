import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';

/// Two phones, one Room, two different rosters.
///
/// One-scan entry opens a seat before it can know who will take it, so a host
/// with an outstanding invite is carrying a durable member nobody is standing
/// in. Those seats are `active`, so they travelled in the accepted-join
/// snapshot like everyone else — but the snapshot had nowhere to say what they
/// were, and they landed on the joining phone as ordinary members: counted in
/// its head count, listed in its roster, and rendered as a nameless person who
/// is not in the room.
void main() {
  late SharedPreferencesRoomRepository host;

  /// Far enough ahead that no wall clock this runs against can put it before
  /// the `createdAt` the repository stamps with `DateTime.now()`. A literal
  /// near today passes until the day it does not — this suite went red when
  /// the date rolled over, on a fixture nothing had touched.
  final at = DateTime.utc(2099, 9, 3);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    host = SharedPreferencesRoomRepository();
  });

  Future<(SavedRoom, RoomMemberId)> openSeat(
    SavedRoom room, {
    required bool pending,
    required String name,
  }) async {
    final invite = await host.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: at,
      ttl: const Duration(hours: 12),
    );
    final verified = await host.verifyAndRedeemInvite(invite, now: at);
    final next = await host.acceptVerifiedInvite(
      verified!,
      displayName: name,
      acceptedAt: at,
      pending: pending,
    );
    return (next, RoomMemberId(invite.invitationId.substring(0, 24)));
  }

  test('an unclaimed seat stays unclaimed on the phone that scans', () async {
    var room = await host.create(name: 'Night ride', localDisplayName: 'Host');
    // A seat for someone else that nobody has used yet.
    final (withSpare, _) = await openSeat(
      room,
      pending: true,
      name: 'Open seat',
    );
    room = withSpare;
    // And the seat the joiner is about to walk through.
    final (issued, joinerId) = await openSeat(
      room,
      pending: true,
      name: 'Open seat',
    );

    expect(issued.room.confirmedMembers, hasLength(1), reason: 'just the host');
    expect(issued.room.pendingMembers, hasLength(2));

    final snapshot = RoomAcceptedJoinSnapshot.fromSavedRoom(
      issued,
      acceptedMemberId: joinerId,
    );
    // Survives the wire, which is where it was being lost.
    final overTheWire = RoomAcceptedJoinSnapshot.decode(snapshot.encode());

    SharedPreferences.setMockInitialValues({});
    final joiner = SharedPreferencesRoomRepository();
    final mine = await joiner.importAcceptedJoin(
      overTheWire,
      localMemberId: joinerId,
    );

    // The joiner is in their own room, and the host's spare seat is still a
    // spare seat rather than a person.
    expect(mine.room.confirmedMembers.map((m) => m.id), contains(joinerId));
    expect(mine.room.confirmedMembers, hasLength(2));
    expect(mine.room.pendingMembers, hasLength(1));
    expect(
      mine.room.confirmedMembers.length,
      issued.room.confirmedMembers.length + 1,
      reason: 'both phones now count the same people, plus the joiner',
    );
  });

  test('the joiner never arrives as a held seat in their own room', () async {
    final room = await host.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, joinerId) = await openSeat(
      room,
      pending: true,
      name: 'Open seat',
    );

    final snapshot = RoomAcceptedJoinSnapshot.decode(
      RoomAcceptedJoinSnapshot.fromSavedRoom(
        issued,
        acceptedMemberId: joinerId,
      ).encode(),
    );
    final mine = snapshot.members.singleWhere((m) => m.memberId == joinerId);
    expect(mine.pending, isFalse);
  });

  test('a roster with no held seats encodes to what it always did', () async {
    final room = await host.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, joinerId) = await openSeat(
      room,
      pending: false,
      name: 'Rider two',
    );

    final encoded = RoomAcceptedJoinSnapshot.fromSavedRoom(
      issued,
      acceptedMemberId: joinerId,
    ).encode();
    // No key, so the payload is byte-identical to one minted before the field
    // existed — and every byte is a QR module a camera has to resolve. Read
    // through the base64, or this passes on any string at all.
    final payload = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    expect(payload.contains('pending'), isFalse);
    final decoded = RoomAcceptedJoinSnapshot.decode(encoded);
    expect(decoded.members.every((m) => !m.pending), isTrue);
  });
}
