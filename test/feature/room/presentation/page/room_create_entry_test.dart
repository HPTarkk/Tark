import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/landing/presentation/widget/room_entry_options.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_create_page.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';
import 'package:tark/feature/room/presentation/page/room_manager_entry.dart';

class _Rooms extends Cubit<RoomListState> implements RoomListCubit {
  _Rooms() : super(const RoomListState());
  final loaded = Completer<void>();
  final created = Completer<SavedRoom?>();
  int createCalls = 0;
  @override
  Future<void> load() async {
    emit(const RoomListState(loading: true));
    await loaded.future;
    if (!isClosed) emit(const RoomListState());
  }

  @override
  Future<bool> needsMoreRoomsAccess({RoomId? existingRoom}) async => false;
  @override
  Future<SavedRoom?> createRoom({
    required String name,
    required String localDisplayName,
  }) {
    createCalls++;
    return created.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Rooms rooms;
  late SharedPreferencesRoomRepository repository;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
    GetIt.instance.registerFactory<RoomListCubit>(() => rooms = _Rooms());
  });
  tearDown(() => GetIt.instance.reset());

  GoRouter router({bool direct = false}) => GoRouter(
    initialLocation: direct
        ? '${AppRoutes.roomsPath}?create=true'
        : AppRoutes.landingPath,
    routes: [
      GoRoute(
        path: AppRoutes.landingPath,
        builder: (_, _) => Scaffold(
          key: const Key('landing'),
          body: SingleChildScrollView(
            child: RoomEntryOptions(repository: repository),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.roomsPath,
        builder: (_, state) => RoomManagerEntry.buildPage(
          createOnOpen: state.uri.queryParameters['create'] == 'true',
        ),
      ),
      GoRoute(
        path: AppRoutes.walkiePath,
        builder: (_, _) => const Scaffold(body: Text('lobby')),
      ),
    ],
  );
  Widget app(GoRouter router) => MaterialApp.router(
    routerConfig: router,
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
  );
  Future<void> arrive(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(RoomListPage, skipOffstage: false), findsNothing);
    }
  }

  testWidgets('Landing New Room opens creation on its first frame', (
    tester,
  ) async {
    final routes = router();
    addTearDown(routes.dispose);
    await tester.pumpWidget(app(routes));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const Key('landing-create-room')));
    await tester.pump();
    expect(find.byType(RoomListPage, skipOffstage: false), findsNothing);
    await tester.pump();
    expect(find.byType(RoomCreatePage), findsOneWidget);
    expect(find.byType(RoomListPage, skipOffstage: false), findsNothing);
    // Storage can finish later without exposing a different screen.
    rooms.loaded.complete();
    await arrive(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('landing')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('direct creation system back returns to Landing', (tester) async {
    final routes = router(direct: true);
    addTearDown(routes.dispose);
    await tester.pumpWidget(app(routes));
    await tester.pump();
    rooms.loaded.complete();
    await arrive(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('landing')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation keeps its ready beat then opens the lobby directly', (
    tester,
  ) async {
    final routes = router(direct: true);
    addTearDown(routes.dispose);
    await tester.pumpWidget(app(routes));
    await tester.pump();
    rooms.loaded.complete();
    await arrive(tester);
    await tester.enterText(find.byKey(const Key('room-name-field')), 'North');
    await tester.pump();
    final submit = find.descendant(
      of: find.byKey(const Key('room-name-submit')),
      matching: find.byType(FilledButton),
    );
    expect(rooms.state.loading, isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('room-name-field')))
          .controller!
          .text,
      'North',
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    expect(submit.hitTestable(), findsOneWidget);
    // Tap the actual action, whose visual shell also contains its entrance.
    await tester.tap(submit);
    await tester.pump();
    await tester.pump();
    expect(rooms.createCalls, 1);
    final now = DateTime.utc(2026, 10, 9);
    rooms.created.complete(
      SavedRoom(
        room: Room(
          id: RoomId('1' * 32),
          name: 'North',
          createdAt: now,
          updatedAt: now,
          members: const [],
        ),
        membership: RoomMembership(
          localMemberId: RoomMemberId('1' * 24),
          canManageInvites: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(RoomCreatePage), findsOneWidget);
    expect(find.text('lobby'), findsNothing);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('lobby'), findsOneWidget);
    expect(find.byType(RoomListPage, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
