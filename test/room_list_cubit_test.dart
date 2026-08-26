import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';

void main() {
  test('load preserves a selected durable room that still exists', () async {
    final repository = _FakeRoomRepository();
    final first = repository.seed('Morning ride');
    repository.seed('Weekend');
    await repository.select(first.room.id);
    final cubit = RoomListCubit(repository);

    await cubit.load();

    expect(cubit.state.rooms, hasLength(2));
    expect(cubit.state.selectedRoomId, first.room.id);
    expect(cubit.state.selectedRoom, first);
    await cubit.close();
  });

  test('load clears stale selected room rather than inventing one', () async {
    final repository = _FakeRoomRepository();
    repository.selected = const RoomId('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    final cubit = RoomListCubit(repository);

    await cubit.load();

    expect(cubit.state.selectedRoomId, isNull);
    expect(repository.selected, isNull);
    await cubit.close();
  });

  test('create selects room but does not start any transport', () async {
    final repository = _FakeRoomRepository();
    final cubit = RoomListCubit(repository);

    final created = await cubit.createRoom(
      name: 'Night riders',
      localDisplayName: 'Rider',
    );

    expect(created, isNotNull);
    expect(repository.selected, created!.room.id);
    expect(cubit.state.selectedRoomId, created.room.id);
    expect(repository.transportStarts, 0);
    await cubit.close();
  });

  test(
    'selected durable room opens logical runtime without transport',
    () async {
      final repository = _FakeRoomRepository();
      final saved = repository.seed('Canonical room');
      await repository.select(saved.room.id);
      final cubit = RoomListCubit(repository);
      await cubit.load();

      final runtime = cubit.openSelectedSession(
        sessionId: 'live-session-1',
        initiallyMuted: true,
      );

      expect(runtime, isNotNull);
      expect(runtime!.state.roomId, saved.room.id.value);
      expect(runtime.state.sessionId, 'live-session-1');
      expect(runtime.state.localMemberId, saved.membership.localMemberId.value);
      expect(runtime.state.memberIds, {saved.membership.localMemberId.value});
      expect(runtime.state.isMuted, isTrue);
      expect(runtime.state.attachment.phase, TransportAttachmentPhase.detached);
      expect(repository.transportStarts, 0);
      await runtime.leave();
      await cubit.close();
    },
  );

  test('archive selected room clears selection and list entry', () async {
    final repository = _FakeRoomRepository();
    final saved = repository.seed('Old ride');
    await repository.select(saved.room.id);
    final cubit = RoomListCubit(repository);
    await cubit.load();

    await cubit.archive(saved.room.id);

    expect(cubit.state.rooms, isEmpty);
    expect(cubit.state.selectedRoomId, isNull);
    expect(repository.selected, isNull);
    await cubit.close();
  });

  test('leave selected room clears selection but keeps saved record', () async {
    final repository = _FakeRoomRepository();
    final saved = repository.seed('Friends');
    await repository.select(saved.room.id);
    final cubit = RoomListCubit(repository);
    await cubit.load();

    await cubit.leave(saved.room.id);

    expect(cubit.state.rooms, hasLength(1));
    expect(cubit.state.rooms.single.membership.active, isFalse);
    expect(cubit.state.selectedRoomId, isNull);
    expect(repository.selected, isNull);
    await cubit.close();
  });
}

class _FakeRoomRepository implements RoomRepository {
  final List<SavedRoom> _rooms = [];
  RoomId? selected;
  var transportStarts = 0;
  var _seed = 0;

  SavedRoom seed(String name) {
    _seed++;
    final hex = _seed.toRadixString(16).padLeft(32, '0');
    final now = DateTime.utc(2026, 8, 25, 12, _seed);
    final saved = SavedRoom(
      room: Room(
        id: RoomId(hex),
        name: name,
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(
            id: RoomMemberId(hex.substring(0, 24)),
            displayName: 'Rider',
            joinedAt: now,
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: RoomMemberId(hex.substring(0, 24)),
        canManageInvites: true,
      ),
    );
    _rooms.add(saved);
    return saved;
  }

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => _rooms
      .where((saved) => includeArchived || !saved.room.archived)
      .toList(growable: false);

  @override
  Future<SavedRoom?> get(RoomId id) async {
    for (final saved in _rooms) {
      if (saved.room.id == id) return saved;
    }
    return null;
  }

  @override
  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  }) async => seed(name);

  @override
  Future<SavedRoom> rename(RoomId id, String name) async {
    final index = _rooms.indexWhere((saved) => saved.room.id == id);
    final current = _rooms[index];
    final renamed = current.copyWith(
      room: current.room.copyWith(
        name: name,
        updatedAt: DateTime.utc(2026, 8, 26),
      ),
    );
    _rooms[index] = renamed;
    return renamed;
  }

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) async {
    final index = _rooms.indexWhere((saved) => saved.room.id == id);
    final current = _rooms[index];
    final updated = current.copyWith(
      room: current.room.copyWith(
        archived: archived,
        updatedAt: DateTime.utc(2026, 8, 26),
      ),
    );
    _rooms[index] = updated;
    return updated;
  }

  @override
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  }) => throw UnimplementedError();

  @override
  Future<VerifiedRoomInvitation?> verifyAndRedeemInvite(
    RoomInvitation invite, {
    required DateTime now,
  }) => throw UnimplementedError();

  @override
  Future<void> revokeInvite(RoomInvitation invite) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> leave(RoomId id) async {
    final index = _rooms.indexWhere((saved) => saved.room.id == id);
    final current = _rooms[index];
    final updated = current.copyWith(
      membership: current.membership.copyWith(active: false),
    );
    _rooms[index] = updated;
    return updated;
  }

  @override
  Future<void> delete(RoomId id) async {
    _rooms.removeWhere((saved) => saved.room.id == id);
  }

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<void> select(RoomId? id) async {
    selected = id;
  }
}
