import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/router/routes.dart';

/// The reported symptom was "no way back from the lobby, and the back gesture
/// closes the app". The control alone does not fix that — the question is where
/// it goes when there is nothing on the stack under it, which is the normal
/// case: the room list, room creation and the join scanner all reach the entry
/// with `go`, which replaces the stack rather than pushing onto it.
void main() {
  Widget stub(String label) => Scaffold(
    body: Center(child: Text(label, key: Key(label))),
  );

  GoRouter buildRouter() => GoRouter(
    initialLocation: AppRoutes.landingPath,
    routes: [
      GoRoute(path: AppRoutes.landingPath, builder: (_, _) => stub('landing')),
      GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => stub('rooms')),
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

  testWidgets('a replaced stack goes up to the room list', (tester) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // How creating a room lands here: `go`, so nothing is underneath.
    router.go(AppRoutes.walkiePath);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('exit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('exit')));
    await tester.pumpAndSettle();

    // Not a dead end, and not the app closing: the surface the room was
    // chosen on.
    expect(find.byKey(const Key('rooms')), findsOneWidget);
  });

  testWidgets('a pushed stack goes back where it came from', (tester) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // How Landing's resume action reaches it: `push`, so back means back.
    router.push(AppRoutes.walkiePath);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('exit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('landing')), findsOneWidget);
    expect(find.byKey(const Key('rooms')), findsNothing);
  });
}
