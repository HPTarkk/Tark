import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

/// Deleting a Room turns its card to dust and closes the gap. The animation
/// is presentation only: the Room is deleted exactly as before, the dust
/// burns out and takes its overlay and image with it, and the rows below end
/// up where the deleted one was.
void main() {
  final getIt = GetIt.instance;
  late SharedPreferencesRoomRepository repository;
  final dust = find.byKey(const Key('room-dissolve-dust'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    getIt.registerSingleton<RoomRepository>(repository);
    getIt.registerFactory<RoomListCubit>(
      () => RoomListCubit(repository, identityStore: _MemoryIdentityStore()),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<List<SavedRoom>> seed(WidgetTester tester) async {
    for (final name in ['Weekend crew', 'Mountain ride', 'Night run']) {
      await repository.create(name: name, localDisplayName: 'Me');
    }
    return repository.list();
  }

  Future<void> pumpPage(WidgetTester tester, {bool reduced = false}) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: RoomListPage.buildPage(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirmDelete(WidgetTester tester, SavedRoom saved) async {
    await tester.tap(find.byKey(Key('room-menu-${saved.room.id.value}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete room').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-sheet-action')));
    // The confirm sheet's own exit, then the dust starts.
    await tester.pump();
  }

  Finder card(SavedRoom saved) =>
      find.byKey(Key('room-${saved.room.id.value}'));

  testWidgets('the deleted card turns to dust, the rows below close the gap, '
      'and everything is cleaned up', (tester) async {
    final rooms = await seed(tester);
    await pumpPage(tester);
    final doomed = rooms[1];
    final below = rooms[2];
    final doomedTop = tester.getTopLeft(card(doomed)).dy;
    final belowTop = tester.getTopLeft(card(below)).dy;
    expect(belowTop, greaterThan(doomedTop));

    await confirmDelete(tester, doomed);
    await tester.pump(const Duration(milliseconds: 16));
    expect(dust, findsOneWidget, reason: 'the card breaks up in an overlay');

    // The row below rises into the gap, never jumping back down.
    var last = tester.getTopLeft(card(below)).dy;
    var rose = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = tester.getTopLeft(card(below)).dy;
      expect(now, lessThanOrEqualTo(last + 0.01));
      if (now < last - 0.01) rose = true;
      last = now;
    }
    expect(rose, isTrue, reason: 'the gap closes over several frames');

    await tester.pumpAndSettle();
    // Deleted, as before.
    final left = await repository.list(includeArchived: true);
    expect(left.map((s) => s.room.id), isNot(contains(doomed.room.id)));
    expect(left, hasLength(2));
    // Gone from the screen, the dust burnt out and its overlay removed.
    expect(card(doomed), findsNothing);
    expect(dust, findsNothing);
    expect(tester.getTopLeft(card(below)).dy, closeTo(doomedTop, 0.5));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: no dust, a short collapse, same delete', (
    tester,
  ) async {
    final rooms = await seed(tester);
    await pumpPage(tester, reduced: true);
    final doomed = rooms[0];

    await confirmDelete(tester, doomed);
    await tester.pump(const Duration(milliseconds: 16));
    expect(dust, findsNothing);

    await tester.pumpAndSettle();
    final left = await repository.list(includeArchived: true);
    expect(left.map((s) => s.room.id), isNot(contains(doomed.room.id)));
    expect(card(doomed), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the screen mid-dissolve disposes cleanly', (
    tester,
  ) async {
    final rooms = await seed(tester);
    await pumpPage(tester);

    await confirmDelete(tester, rooms[0]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(dust, findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(dust, findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}

final class _MemoryIdentityStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    _values.remove(_key(roomId, memberId));
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values[_key(roomId, memberId)];

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    _values[_key(roomId, memberId)] = material;
  }
}
