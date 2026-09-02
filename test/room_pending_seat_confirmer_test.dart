import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_pending_seat_confirmer.dart';
import 'package:tark/feature/room/presentation/room_member_display_name.dart';

/// A seat opened by an invite is a placeholder — the host has to open it before
/// it can know who will take it — so it starts pending and is deliberately left
/// out of every count. R7 clears that mark when the joiner opens the Room screen
/// and writes their own name over it. A rider who joins and simply rides never
/// does, so the host is left looking at "open seat" for someone they are talking
/// to. A verified live route proof settles it with nobody tapping anything.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A room whose host holds one confirmed seat and one open invite seat.
  Future<({SharedPreferencesRoomRepository rooms, SavedRoom saved})>
  roomWithHeldSeat() async {
    final rooms = SharedPreferencesRoomRepository();
    final created = await rooms.create(
      name: 'Night ride',
      localDisplayName: 'Rider A',
    );
    final now = DateTime.utc(2026, 9, 2, 9);
    final invite = await rooms.issueInvite(
      created.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 12),
    );
    final verified = await rooms.verifyAndRedeemInvite(
      invite,
      now: now.add(const Duration(minutes: 1)),
    );
    final saved = await rooms.acceptVerifiedInvite(
      verified!,
      displayName: 'Open seat',
      acceptedAt: now.add(const Duration(minutes: 1)),
      pending: true,
    );
    return (rooms: rooms, saved: saved);
  }

  RoomMemberId heldSeatOf(SavedRoom saved) => saved.room.pendingMembers.single.id;

  test('a proven member takes their held seat', () async {
    final subject = await roomWithHeldSeat();
    final seat = heldSeatOf(subject.saved);
    final confirmer = RoomPendingSeatConfirmer(
      rooms: subject.rooms,
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);

    expect(await confirmer.confirm(seat), isTrue);

    final room = (await subject.rooms.get(subject.saved.room.id))!.room;
    expect(room.pendingMembers, isEmpty);
    expect(room.confirmedMembers.map((member) => member.id), contains(seat));
    // The stored placeholder is deliberately left alone: an empty display name
    // is a corrupt record to `_decodeMember`, and `_decodeRoom` answers that by
    // dropping the whole room. It is unwritten at the point of display instead
    // — `roomMemberDisplayName` renders a confirmed seat still carrying it as
    // "Unnamed" rather than as a seat that is still open.
    final row = room.members.firstWhere((member) => member.id == seat);
    expect(row.displayName, 'Open seat');
    expect(
      roomMemberDisplayName(row, fa: false, unnamed: 'Unnamed'),
      'Unnamed',
    );
    // And the same row while it was still pending said the opposite.
    expect(
      roomMemberDisplayName(
        row.copyWith(pending: true),
        fa: false,
        unnamed: 'Unnamed',
      ),
      'Open seat',
    );
    // Locale drift too: the string is frozen in whichever language the host
    // was using when they opened the seat.
    expect(
      roomMemberDisplayName(row, fa: true, unnamed: 'بدون نام'),
      'بدون نام',
    );
  });

  test('a second proof does not go back to storage', () async {
    final subject = await roomWithHeldSeat();
    final counting = _CountingRooms(subject.rooms);
    final confirmer = RoomPendingSeatConfirmer(
      rooms: counting,
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);
    final seat = heldSeatOf(subject.saved);

    expect(await confirmer.confirm(seat), isTrue);
    final readsAfterFirst = counting.reads;

    // Proof arrives on every challenge cycle for as long as the ride lasts, so
    // an un-cached confirmer would re-read the whole roster every few seconds.
    for (var i = 0; i < 5; i++) {
      expect(await confirmer.confirm(seat), isFalse);
    }
    expect(counting.reads, readsAfterFirst);
    expect(counting.writes, 1);
  });

  test('a member who was already confirmed is left alone', () async {
    final subject = await roomWithHeldSeat();
    final counting = _CountingRooms(subject.rooms);
    final confirmer = RoomPendingSeatConfirmer(
      rooms: counting,
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);

    expect(
      await confirmer.confirm(subject.saved.membership.localMemberId),
      isFalse,
    );
    expect(counting.writes, 0);
  });

  test('a withdrawn seat is not brought back', () async {
    final subject = await roomWithHeldSeat();
    final seat = heldSeatOf(subject.saved);
    await subject.rooms.removeMember(subject.saved.room.id, seat);

    final confirmer = RoomPendingSeatConfirmer(
      rooms: subject.rooms,
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);

    // A host who revoked an invite while its holder is still on the air made a
    // decision. Evidence must not quietly reverse it — the proof only says a
    // member is present, never that they should be.
    expect(await confirmer.confirm(seat), isFalse);
    final room = (await subject.rooms.get(subject.saved.room.id))!.room;
    expect(room.confirmedMembers.map((member) => member.id), isNot(contains(seat)));
    expect(room.activeMembers.map((member) => member.id), isNot(contains(seat)));
  });

  test('a member who is not on this roster changes nothing', () async {
    final subject = await roomWithHeldSeat();
    final counting = _CountingRooms(subject.rooms);
    final confirmer = RoomPendingSeatConfirmer(
      rooms: counting,
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);

    expect(
      await confirmer.confirm(const RoomMemberId('999999999999999999999999')),
      isFalse,
    );
    expect(counting.writes, 0);
    expect(
      (await subject.rooms.get(subject.saved.room.id))!.room.pendingMembers,
      hasLength(1),
    );
  });

  test('a storage failure cannot reach the live session', () async {
    final subject = await roomWithHeldSeat();
    final confirmer = RoomPendingSeatConfirmer(
      rooms: _BrokenRooms(subject.rooms),
      roomId: subject.saved.room.id,
    );
    addTearDown(confirmer.dispose);

    // This runs on the path that admits live capability evidence during a call.
    // Nothing about bookkeeping a roster row is worth throwing there.
    expect(await confirmer.confirm(heldSeatOf(subject.saved)), isFalse);
  });

  test('a disposed confirmer stops writing', () async {
    final subject = await roomWithHeldSeat();
    final counting = _CountingRooms(subject.rooms);
    final confirmer = RoomPendingSeatConfirmer(
      rooms: counting,
      roomId: subject.saved.room.id,
    )..dispose();

    expect(await confirmer.confirm(heldSeatOf(subject.saved)), isFalse);
    expect(counting.writes, 0);
  });
}

class _CountingRooms implements RoomRepository {
  _CountingRooms(this._inner);

  final RoomRepository _inner;
  int reads = 0;
  int writes = 0;

  @override
  Future<SavedRoom?> get(RoomId id) {
    reads++;
    return _inner.get(id);
  }

  @override
  Future<SavedRoom> updateMember(
    RoomId id,
    RoomMemberId memberId, {
    String? displayName,
    bool? pending,
  }) {
    writes++;
    return _inner.updateMember(
      id,
      memberId,
      displayName: displayName,
      pending: pending,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BrokenRooms implements RoomRepository {
  _BrokenRooms(this._inner);

  final RoomRepository _inner;

  @override
  Future<SavedRoom?> get(RoomId id) async => _inner.get(id);

  @override
  Future<SavedRoom> updateMember(
    RoomId id,
    RoomMemberId memberId, {
    String? displayName,
    bool? pending,
  }) async => throw StateError('storage is gone');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
