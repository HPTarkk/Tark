import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_pending_seat_confirmer.dart';

/// R27c. Every "Create invite" tap mints a durable seat, and nothing used to
/// expire it — the *invite* had a 12h TTL, the *seat* had none. A host who
/// tapped twice (a scan that did not take, a code shown and dismissed) was left
/// with a permanent «جای خالی» row.
///
/// The rule is that the seat is the code's shadow: it is held for exactly as
/// long as the code can be redeemed, and past that nobody can ever walk through
/// it. Every other obvious rule is wrong — revoking the previous seat breaks
/// inviting two people, and revoking on "Done" kicks out someone who has just
/// scanned but whose proof has not landed yet — so those two cases are pinned
/// here alongside the expiry itself.
/// Far enough in the past that no wall clock this runs against can disagree.
final _longExpired = DateTime.utc(2020);

void main() {
  const ttl = Duration(hours: 12);
  final issuedAt = DateTime.utc(2099, 9, 3, 9);

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<(SavedRoom, RoomMemberId)> openSeat(
    SharedPreferencesRoomRepository rooms,
    SavedRoom room, {
    Duration? hold = ttl,
  }) async {
    final invite = await rooms.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: issuedAt,
      ttl: ttl,
    );
    final verified = await rooms.verifyAndRedeemInvite(invite, now: issuedAt);
    final next = await rooms.acceptVerifiedInvite(
      verified!,
      displayName: 'Open seat',
      acceptedAt: issuedAt,
      pending: true,
      // Null is what a seat opened before R27c looks like.
      heldUntil: hold == null ? null : invite.expiresAt,
    );
    return (next, RoomMemberId(invite.invitationId.substring(0, 24)));
  }

  test('a seat is held for exactly as long as its code', () {
    final seat = RoomMember(
      id: const RoomMemberId('222222222222222222222222'),
      displayName: 'Open seat',
      joinedAt: issuedAt,
      pending: true,
      heldUntil: issuedAt.add(ttl),
    );

    expect(seat.isExpiredHeldSeat(issuedAt), isFalse);
    expect(
      seat.isExpiredHeldSeat(issuedAt.add(ttl - const Duration(minutes: 1))),
      isFalse,
    );
    expect(seat.isExpiredHeldSeat(issuedAt.add(ttl)), isTrue);
  });

  test('an abandoned seat is gone from the roster once its code dies', () async {
    final rooms = SharedPreferencesRoomRepository();
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, seat) = await openSeat(rooms, created);

    expect(issued.room.pendingMembers, hasLength(1));

    // The clock is real here — the sweep runs on read, against `now` — so the
    // seat is aged by rewriting the record with a hold that has already passed
    // rather than by waiting twelve hours.
    await _ageSeat(rooms, issued, seat, to: _longExpired);

    final after = (await rooms.get(created.room.id))!.room;
    expect(after.pendingMembers, isEmpty);
    expect(after.confirmedMembers, hasLength(1), reason: 'just the host');
    // Withdrawn, not deleted: `removedAt` is the way every other departure is
    // recorded, so nothing downstream needs a second notion of "gone".
    final row = after.members.firstWhere((member) => member.id == seat);
    expect(row.isActive, isFalse);
    expect(row.removedAt, row.heldUntil);
  });

  test('two outstanding invites both survive', () async {
    final rooms = SharedPreferencesRoomRepository();
    var room = await rooms.create(name: 'Night ride', localDisplayName: 'Host');
    final (withFirst, _) = await openSeat(rooms, room);
    room = withFirst;
    final (withSecond, _) = await openSeat(rooms, room);

    // The case that rules out "revoke the previous seat": a host inviting two
    // people taps twice, and both seats have to be waiting when they arrive.
    expect(withSecond.room.pendingMembers, hasLength(2));
    expect(withSecond.room.confirmedMembers, hasLength(1));
  });

  test('a seat somebody is standing in can never expire', () async {
    final rooms = SharedPreferencesRoomRepository();
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, seat) = await openSeat(rooms, created);

    final confirmer = RoomPendingSeatConfirmer(
      rooms: rooms,
      roomId: created.room.id,
    );
    addTearDown(confirmer.dispose);
    expect(await confirmer.confirm(seat, displayName: 'Rider B'), isTrue);

    // The hold goes with the mark. Left behind, it would have expired a
    // confirmed member's row out from under them twelve hours into a trip.
    final row = (await rooms.get(created.room.id))!.room.members.firstWhere(
      (member) => member.id == seat,
    );
    expect(row.pending, isFalse);
    expect(row.heldUntil, isNull);

    await _touch(rooms, issued);
    final after = (await rooms.get(created.room.id))!.room;
    expect(after.confirmedMembers.map((member) => member.id), contains(seat));
  });

  test('a seat opened before R27c is held indefinitely, as it was', () async {
    final rooms = SharedPreferencesRoomRepository();
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, seat) = await openSeat(rooms, created, hold: null);

    expect(issued.room.pendingMembers.single.heldUntil, isNull);
    // Rooms already on people's phones were never given this rule and must not
    // be swept by it. The host takes those seats back by hand, as before.
    final after = (await rooms.get(created.room.id))!.room;
    expect(after.pendingMembers.map((member) => member.id), contains(seat));
  });

  test('an expired seat is not resurrected by a late proof', () async {
    final rooms = SharedPreferencesRoomRepository();
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final (issued, seat) = await openSeat(rooms, created);
    await _ageSeat(rooms, issued, seat, to: _longExpired);

    final confirmer = RoomPendingSeatConfirmer(
      rooms: rooms,
      roomId: created.room.id,
    );
    addTearDown(confirmer.dispose);

    // Evidence says a member is present, never that they should be. Re-admitting
    // is an authorization change and belongs to the host.
    expect(await confirmer.confirm(seat, displayName: 'Rider B'), isFalse);
    expect((await rooms.get(created.room.id))!.room.activeMembers, hasLength(1));
  });

  test('the hold travels to the phone that scans', () async {
    final rooms = SharedPreferencesRoomRepository();
    var room = await rooms.create(name: 'Night ride', localDisplayName: 'Host');
    final (withSpare, spare) = await openSeat(rooms, room);
    room = withSpare;
    final (issued, joiner) = await openSeat(rooms, room);

    final snapshot = RoomAcceptedJoinSnapshot.decode(
      RoomAcceptedJoinSnapshot.fromSavedRoom(
        issued,
        acceptedMemberId: joiner,
      ).encode(),
    );

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final joinerRooms = SharedPreferencesRoomRepository();
    final mine = await joinerRooms.importAcceptedJoin(
      snapshot,
      localMemberId: joiner,
    );

    // Without this the joining phone keeps the host's spare seat forever: it
    // has no back-channel, so a seat that clears on one roster and not the
    // other is R27's divergence one phone over.
    final theirSpare = mine.room.members.firstWhere(
      (member) => member.id == spare,
    );
    expect(theirSpare.pending, isTrue);
    expect(theirSpare.heldUntil, issuedAt.add(ttl));
    // And the joiner's own seat has no hold, because they are standing in it.
    expect(
      mine.room.members.firstWhere((member) => member.id == joiner).heldUntil,
      isNull,
    );
  });
}

/// Rewrites [seat]'s hold to an instant already past, then re-reads.
///
/// The sweep runs against the wall clock on the way out of storage, so the way
/// to test it is to move the seat rather than the clock.
Future<void> _ageSeat(
  SharedPreferencesRoomRepository rooms,
  SavedRoom saved,
  RoomMemberId seat, {
  required DateTime to,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final key = 'rooms.v1.room.${saved.room.id.value}';
  final json = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
  for (final member in json['members'] as List) {
    final row = member as Map<String, dynamic>;
    if (row['id'] == seat.value) row['heldUntil'] = to.toIso8601String();
  }
  await prefs.setString(key, jsonEncode(json));
}

/// Any durable write, to prove the sweep is not what re-reading depends on.
Future<void> _touch(
  SharedPreferencesRoomRepository rooms,
  SavedRoom saved,
) => rooms.rename(saved.room.id, 'Night ride, later');
