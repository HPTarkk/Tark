import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('saved rooms stay usable at 320px and selection is durable only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final first = _savedRoom('1' * 32, 'Weekend crew', memberCount: 3);
    final second = _savedRoom('2' * 32, 'Mountain ride', memberCount: 2);
    final repository = _FakeRoomRepository(
      rooms: [first, second],
      selected: second.room.id,
    );
    getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));

    await tester.pumpWidget(_app(const Locale('en'), RoomListPage.buildPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rooms-list')), findsOneWidget);
    expect(find.text('Weekend crew'), findsOneWidget);
    expect(find.text('Mountain ride'), findsOneWidget);
    expect(find.text('Selected'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Select this room'));
    await tester.pumpAndSettle();

    expect(repository.selected, first.room.id);
    expect(repository.transportStarts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Persian saved rooms page is RTL at 320px', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repository = _FakeRoomRepository(
      rooms: [_savedRoom('a' * 32, 'گروه جمعه', memberCount: 4)],
    );
    getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));

    await tester.pumpWidget(_app(const Locale('fa'), RoomListPage.buildPage()));
    await tester.pumpAndSettle();

    expect(find.text('اتاق‌های ذخیره‌شده'), findsOneWidget);
    expect(find.text('گروه جمعه'), findsOneWidget);
    final title = tester.element(find.text('اتاق‌های ذخیره‌شده'));
    expect(Directionality.of(title), TextDirection.rtl);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('fa')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

SavedRoom _savedRoom(String id, String name, {required int memberCount}) {
  final now = DateTime.utc(2026, 8, 25);
  final members = List.generate(
    memberCount,
    (index) => RoomMember(
      id: RoomMemberId('${id.substring(0, 20)}${index.toString().padLeft(4, '0')}'),
      displayName: 'Rider ${index + 1}',
      joinedAt: now,
    ),
  );
  return SavedRoom(
    room: Room(
      id: RoomId(id),
      name: name,
      createdAt: now,
      updatedAt: now,
      members: members,
    ),
    membership: RoomMembership(
      localMemberId: members.first.id,
      canManageInvites: true,
    ),
  );
}

class _FakeRoomRepository implements RoomRepository {
  _FakeRoomRepository({required List<SavedRoom> rooms, RoomId? selected})
    : _rooms = List.of(rooms),
      selected = selected;

  final List<SavedRoom> _rooms;
  RoomId? selected;
  int transportStarts = 0;

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
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> rename(RoomId id, String name) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SavedRoom> leave(RoomId id) async {
    throw UnimplementedError();
  }

  @override
  Future<void> delete(RoomId id) async {
    throw UnimplementedError();
  }

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<void> select(RoomId? id) async {
    selected = id;
  }
}
