import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/route_exit.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_list_page.dart';

/// R19 gave the lobby a way out by falling through to the room list when there
/// was nothing to pop. That `go` replaces the stack — so it moved the dead end
/// one screen up rather than removing it: land on the room list this way and
/// its back control silently vanished, because `AppBar` only draws one when the
/// navigator has something to pop.
///
/// The reported route is exactly that round trip: landing → rooms (back
/// present) → a room → start → back → rooms, and now no back at all.
void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final repository = SharedPreferencesRoomRepository();
    getIt.registerSingleton<RoomRepository>(repository);
    getIt.registerFactory<RoomListCubit>(() => RoomListCubit(repository));
  });

  tearDown(() async {
    await getIt.reset();
  });

  Widget stub(String label) => Scaffold(
    body: Center(child: Text(label, key: Key(label))),
  );

  GoRouter buildRouter() => GoRouter(
    initialLocation: AppRoutes.landingPath,
    routes: [
      GoRoute(path: AppRoutes.landingPath, builder: (_, _) => stub('landing')),
      GoRoute(
        path: AppRoutes.roomsPath,
        builder: (_, _) => RoomListPage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.walkiePath,
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('exit'),
              onPressed: () => leaveRoomEntry(context),
              child: const Text('exit'),
            ),
          ),
        ),
      ),
    ],
  );

  Widget app(GoRouter router) => MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
  );

  testWidgets('the room list keeps a way out after the round trip', (
    tester,
  ) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();

    // Landing → rooms, the way the landing CTA does it.
    router.push(AppRoutes.roomsPath);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rooms-back')), findsOneWidget);

    // Starting a room replaces the stack, and leaving the lobby lands back
    // here the same way.
    router.go(AppRoutes.walkiePath);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rooms-empty')), findsOneWidget);

    // The control that used to disappear at exactly this point.
    expect(find.byKey(const Key('rooms-back')), findsOneWidget);

    await tester.tap(find.byKey(const Key('rooms-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('landing')), findsOneWidget);
  });

  testWidgets('a pushed room list still goes back where it came from', (
    tester,
  ) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();

    router.push(AppRoutes.roomsPath);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rooms-back')));
    await tester.pumpAndSettle();

    // Popping, not going: the user pushed their way here and expects to
    // retrace it, which is the half `go` on its own would get wrong.
    expect(find.byKey(const Key('landing')), findsOneWidget);
  });

  testWidgets('the system gesture and the control agree', (tester) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(app(router));
    await tester.pumpAndSettle();

    // Reached with `go`, so there is nothing under it: an unhandled back here
    // closed the app rather than leaving the screen.
    router.go(AppRoutes.roomsPath);
    await tester.pumpAndSettle();

    final scope = tester.widget<RouteExitScope>(
      find.byType(RouteExitScope).first,
    );
    scope.onExit();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('landing')), findsOneWidget);
  });
}
