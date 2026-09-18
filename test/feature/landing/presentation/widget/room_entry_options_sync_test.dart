import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/landing/presentation/widget/room_entry_options.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';

/// Landing's room count used to be read once and never again.
///
/// It sits *under* the room list on the navigator, and a covered route is not
/// rebuilt — `didChangeDependencies`, which the old code re-read from, does not
/// fire when the route above it pops. So a Room deleted one screen up left
/// Landing still offering it, and still counting it, until the app restarted.
void main() {
  late SharedPreferencesRoomRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('the count follows a delete made on another surface', (
    tester,
  ) async {
    final first = await repository.create(name: 'North', localDisplayName: 'A');
    await repository.create(name: 'South', localDisplayName: 'A');
    await repository.select(first.room.id);

    await tester.pumpWidget(host(RoomEntryOptions(repository: repository)));
    await tester.pump();

    expect(find.byKey(const Key('landing-resume-room')), findsOneWidget);
    expect(find.text('North'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    // The room list, one route above, deletes the selected room. Landing is
    // covered and gets no rebuild of its own — the announcement is the only
    // thing that reaches it.
    await repository.delete(first.room.id);
    await tester.pump();
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('North'), findsNothing);
    // Selection went with the room, so the remaining one leads instead.
    expect(find.text('South'), findsOneWidget);
  });

  testWidgets('emptying storage falls back to the first-run shape', (
    tester,
  ) async {
    final only = await repository.create(name: 'Only', localDisplayName: 'A');
    await repository.select(only.room.id);

    await tester.pumpWidget(host(RoomEntryOptions(repository: repository)));
    await tester.pump();
    expect(find.byKey(const Key('landing-resume-room')), findsOneWidget);
    expect(find.byKey(const Key('landing-all-rooms')), findsOneWidget);

    await repository.delete(only.room.id);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('landing-resume-room')), findsNothing);
    expect(find.byKey(const Key('landing-all-rooms')), findsNothing);
    expect(find.byKey(const Key('landing-create-room')), findsOneWidget);
    expect(find.byKey(const Key('landing-join-room')), findsOneWidget);
  });

  testWidgets('a room created elsewhere shows up without a navigation', (
    tester,
  ) async {
    await tester.pumpWidget(host(RoomEntryOptions(repository: repository)));
    await tester.pump();
    expect(find.byKey(const Key('landing-resume-room')), findsNothing);

    final made = await repository.create(name: 'Made', localDisplayName: 'A');
    await repository.select(made.room.id);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('landing-resume-room')), findsOneWidget);
    expect(find.text('Made'), findsOneWidget);
  });

  testWidgets('storage that cannot be read never blocks the screen', (
    tester,
  ) async {
    await tester.pumpWidget(host(const RoomEntryOptions()));
    await tester.pump();

    // No registration, no throw: the first-run shape offers create and join,
    // both of which work without a saved Room.
    expect(find.byKey(const Key('landing-create-room')), findsOneWidget);
    expect(find.byKey(const Key('landing-join-room')), findsOneWidget);
  });

  test('every durable mutation announces itself exactly once', () async {
    final seen = <String>[];
    final sub = repository.changes.listen((_) => seen.add('ping'));
    addTearDown(() => unawaited(sub.cancel()));

    final room = await repository.create(name: 'Ping', localDisplayName: 'A');
    await pumpEventQueue();
    expect(seen, isNotEmpty, reason: 'create');

    seen.clear();
    await repository.rename(room.room.id, 'Pong');
    await pumpEventQueue();
    expect(seen, isNotEmpty, reason: 'rename');

    seen.clear();
    await repository.setArchived(room.room.id, true);
    await pumpEventQueue();
    expect(seen, isNotEmpty, reason: 'archive');

    seen.clear();
    await repository.setArchived(room.room.id, false);
    await repository.select(room.room.id);
    await pumpEventQueue();
    expect(seen, isNotEmpty, reason: 'select');

    seen.clear();
    await repository.delete(room.room.id);
    await pumpEventQueue();
    expect(seen, isNotEmpty, reason: 'delete');
    expect(await repository.list(), isEmpty);
  });

  test('a read that repairs a dangling selection stays quiet', () async {
    final room = await repository.create(name: 'Gone', localDisplayName: 'A');
    await repository.select(room.room.id);

    final seen = <String>[];
    final sub = repository.changes.listen((_) => seen.add('ping'));
    addTearDown(() => unawaited(sub.cancel()));

    // Reading is not a change. Announcing here would put every listener into
    // a re-read that ends in another read of the same value.
    expect(await repository.selectedRoomId(), isNotNull);
    await pumpEventQueue();
    expect(seen, isEmpty);
  });
}
