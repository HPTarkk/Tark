import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

/// Archive used to be a one-way door — `setArchived` hid the Room and nothing
/// in the app ever passed `includeArchived: true`, so a put-away Room was
/// invisible forever and still on disk. These pin the way back out, and the
/// separate delete that archive was standing in for.
void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('the archive is invisible until something is in it', (
    tester,
  ) async {
    final repository = _FakeRoomRepository(
      rooms: [_savedRoom('1' * 32, 'Weekend crew')],
    );
    await _pump(tester, getIt, repository);

    expect(find.byKey(const Key('rooms-archive-action')), findsNothing);

    await _archiveFromMenu(tester, '1' * 32);

    expect(find.byKey(const Key('rooms-archive-action')), findsOneWidget);
    // ...and it has left the live list, without leaving storage.
    expect(find.text('Weekend crew'), findsNothing);
    expect(repository.rooms, hasLength(1));
  });

  testWidgets('an archived room can be restored from the sheet', (
    tester,
  ) async {
    final room = _savedRoom('1' * 32, 'Weekend crew', archived: true);
    final repository = _FakeRoomRepository(
      rooms: [room, _savedRoom('2' * 32, 'Mountain ride')],
    );
    await _pump(tester, getIt, repository);

    await tester.tap(find.byKey(const Key('rooms-archive-action')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('archived-${room.room.id.value}')), findsOneWidget);

    await tester.tap(find.byKey(Key('restore-${room.room.id.value}')));
    await tester.pumpAndSettle();

    // The sheet closes itself once its subject is gone, and the room is back
    // in the list behind it.
    expect(find.byKey(Key('archived-${room.room.id.value}')), findsNothing);
    expect(find.text('Weekend crew'), findsOneWidget);
    expect(
      repository.rooms
          .firstWhere((s) => s.room.id == room.room.id)
          .room
          .archived,
      isFalse,
    );
  });

  testWidgets('restoring does not silently re-select the room', (tester) async {
    final archived = _savedRoom('1' * 32, 'Weekend crew', archived: true);
    final live = _savedRoom('2' * 32, 'Mountain ride');
    final repository = _FakeRoomRepository(
      rooms: [archived, live],
      selected: live.room.id,
    );
    await _pump(tester, getIt, repository);

    await tester.tap(find.byKey(const Key('rooms-archive-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('restore-${archived.room.id.value}')));
    await tester.pumpAndSettle();

    // Coming back from the archive is a filing decision. Repointing Start at a
    // room the user has not looked at in weeks is not what they asked for.
    expect(repository.selected, live.room.id);
  });

  testWidgets('delete asks first, and cancelling keeps the room', (
    tester,
  ) async {
    final room = _savedRoom('1' * 32, 'Weekend crew', archived: true);
    final repository = _FakeRoomRepository(rooms: [room]);
    await _pump(tester, getIt, repository);

    await tester.tap(find.byKey(const Key('rooms-archive-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete-${room.room.id.value}')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('confirm-sheet-action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-sheet-cancel')));
    await tester.pumpAndSettle();

    expect(repository.rooms, hasLength(1));
    expect(repository.deleted, isEmpty);
  });

  testWidgets('confirming delete removes the room and its identity', (
    tester,
  ) async {
    final room = _savedRoom('1' * 32, 'Weekend crew', archived: true);
    final repository = _FakeRoomRepository(rooms: [room]);
    repository.identityStore.seed(room);
    await _pump(tester, getIt, repository);

    await tester.tap(find.byKey(const Key('rooms-archive-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete-${room.room.id.value}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sheet-action')));
    await tester.pumpAndSettle();

    expect(repository.rooms, isEmpty);
    expect(repository.deleted, [room.room.id]);
    // The transport key goes with the record. Leaving it behind would mean a
    // deleted Room quietly keeping its private material in the secure store.
    expect(repository.identityStore.values, isEmpty);
    // Nothing is left on screen claiming the room still exists.
    expect(find.byKey(const Key('rooms-archive-action')), findsNothing);
    expect(find.text('Weekend crew'), findsNothing);
  });

  testWidgets('a live room can be deleted straight from its menu', (
    tester,
  ) async {
    final id = '1' * 32;
    final repository = _FakeRoomRepository(
      rooms: [_savedRoom(id, 'Weekend crew')],
    );
    await _pump(tester, getIt, repository);

    await tester.tap(find.byKey(Key('room-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete room').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sheet-action')));
    await tester.pumpAndSettle();

    expect(repository.rooms, isEmpty);
  });

  testWidgets('the archive reads right-to-left in Persian at 320px', (
    tester,
  ) async {
    // The app bar now carries a title and the archive pill. Persian titles are
    // the long ones, and 320px is the floor this app supports.
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeRoomRepository(
      rooms: [
        _savedRoom('1' * 32, 'گروه جمعه', archived: true),
        _savedRoom('2' * 32, 'مسیر کوهستان'),
      ],
    );
    await _pump(tester, getIt, repository, locale: const Locale('fa'));

    expect(find.byKey(const Key('rooms-archive-action')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('rooms-archive-action')));
    await tester.pumpAndSettle();

    final title = tester.element(find.text('اتاق‌های بایگانی‌شده').first);
    expect(Directionality.of(title), TextDirection.rtl);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester,
  GetIt getIt,
  _FakeRoomRepository repository, {
  Locale locale = const Locale('en'),
}) async {
  getIt.registerFactory<RoomListCubit>(
    () => RoomListCubit(repository, identityStore: repository.identityStore),
  );
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: RoomListPage.buildPage(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _archiveFromMenu(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('room-menu-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Archive').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('confirm-sheet-action')));
  await tester.pumpAndSettle();
}

SavedRoom _savedRoom(String id, String name, {bool archived = false}) {
  final now = DateTime.utc(2026, 8, 25);
  final member = RoomMember(
    id: RoomMemberId('${id.substring(0, 20)}0000'),
    displayName: 'Rider',
    joinedAt: now,
  );
  return SavedRoom(
    room: Room(
      id: RoomId(id),
      name: name,
      createdAt: now,
      updatedAt: now,
      members: [member],
      archived: archived,
    ),
    membership: RoomMembership(
      localMemberId: member.id,
      canManageInvites: true,
    ),
  );
}

class _FakeRoomRepository implements RoomRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  _FakeRoomRepository({required List<SavedRoom> rooms, this.selected})
    : rooms = List.of(rooms);

  final List<SavedRoom> rooms;
  final deleted = <RoomId>[];
  final identityStore = _MemoryIdentityStore();
  RoomId? selected;

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => rooms
      .where((saved) => includeArchived || !saved.room.archived)
      .toList(growable: false);

  @override
  Future<SavedRoom?> get(RoomId id) async {
    for (final saved in rooms) {
      if (saved.room.id == id) return saved;
    }
    return null;
  }

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) async {
    final index = rooms.indexWhere((saved) => saved.room.id == id);
    final current = rooms[index];
    final updated = current.copyWith(
      room: current.room.copyWith(archived: archived),
    );
    rooms[index] = updated;
    return updated;
  }

  @override
  Future<void> delete(RoomId id) async {
    deleted.add(id);
    rooms.removeWhere((saved) => saved.room.id == id);
    // Mirrors the real repository, which drops a selection pointing at a room
    // it just removed.
    if (selected == id) selected = null;
  }

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<void> select(RoomId? id) async {
    selected = id;
  }

  @override
  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> rename(RoomId id, String name) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> leave(RoomId id) => throw UnimplementedError();

  @override
  Future<SavedRoom> removeMember(RoomId id, RoomMemberId memberId) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> updateMember(
    RoomId id,
    RoomMemberId memberId, {
    String? displayName,
    bool? pending,
  }) => throw UnimplementedError();

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
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
    bool pending = false,
    DateTime? heldUntil,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  }) => throw UnimplementedError();

  @override
  Future<void> revokeInvite(RoomInvitation invite) =>
      throw UnimplementedError();
}

/// The transport key a deleted Room leaves behind if nobody clears it.
final class _MemoryIdentityStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> values = {};

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    values.remove(_key(roomId, memberId));
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => values[_key(roomId, memberId)];

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    values[_key(roomId, memberId)] = material;
  }

  /// Puts a key in the store for [saved]'s local member, so a test can watch
  /// it be cleared.
  void seed(SavedRoom saved) {
    final keyPair = RoomMemberTransportKeyPair(
      privateKey: List<int>.filled(32, 1),
      publicKey: List<int>.filled(32, 2),
    );
    values[_key(
      saved.room.id,
      saved.membership.localMemberId,
    )] = RoomTransportIdentityMaterial(
      memberKeyPair: keyPair,
      certificate: RoomMemberTransportCertificate(
        roomId: saved.room.id,
        memberId: saved.membership.localMemberId,
        memberPublicKey: keyPair.publicKey,
        issuerPublicKey: List<int>.filled(32, 3),
        issuerSignature: List<int>.filled(64, 4),
      ),
    );
  }
}
