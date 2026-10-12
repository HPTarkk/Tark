import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/utils/extensions.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_create_page.dart';

class _Rooms extends Cubit<RoomListState> implements RoomListCubit {
  _Rooms() : super(const RoomListState());
  final creation = Completer<SavedRoom?>();
  int calls = 0;
  String? name;
  @override
  Future<bool> needsMoreRoomsAccess({RoomId? existingRoom}) async => false;
  @override
  Future<SavedRoom?> createRoom({
    required String name,
    required String localDisplayName,
  }) {
    calls++;
    this.name = name;
    return creation.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _app(
  _Rooms cubit, {
  double scale = 1,
  bool reduced = false,
  String language = 'fa',
  ValueChanged<SavedRoom?>? onResult,
}) => MaterialApp(
  locale: Locale(language),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduced,
    ),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () async {
          final result = await Navigator.of(context).push<SavedRoom>(
            MaterialPageRoute(
              builder: (_) => BlocProvider<RoomListCubit>.value(
                value: cubit,
                child: const RoomCreatePage(),
              ),
            ),
          );
          onResult?.call(result);
        },
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> _open(
  WidgetTester tester,
  _Rooms rooms, {
  double scale = 1,
  bool reduced = false,
  String language = 'fa',
  ValueChanged<SavedRoom?>? onResult,
}) async {
  await tester.pumpWidget(
    _app(
      rooms,
      scale: scale,
      reduced: reduced,
      language: language,
      onResult: onResult,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  for (var i = 0; i < 36; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

SavedRoom _room(String name) {
  final now = DateTime.utc(2026, 10, 9);
  return SavedRoom(
    room: Room(
      id: RoomId('1' * 32),
      name: name,
      createdAt: now,
      updatedAt: now,
      members: const [],
    ),
    membership: RoomMembership(
      localMemberId: RoomMemberId('1' * 24),
      canManageInvites: true,
    ),
  );
}

/// Product of every [Opacity] above [finder].
double _opacity(WidgetTester tester, Finder finder) => find
    .ancestor(of: finder, matching: find.byType(Opacity))
    .evaluate()
    .fold(1.0, (value, e) => value * (e.widget as Opacity).opacity);

Future<void> _submit(WidgetTester tester, String name) async {
  await tester.enterText(find.byKey(const Key('room-name-field')), name);
  await tester.pump();
  await tester.tap(find.byKey(const Key('room-name-submit')));
  await tester.pump();
}

void main() {
  tearDown(() => GetIt.instance.reset());

  for (final (language, typed, shown) in [
    ('fa', 'سفر 2 ٣', 'سفر ۲ ۳'),
    ('en', 'Ride ۲ ٣', 'Ride 2 3'),
  ]) {
    testWidgets('$language: digits in the room name read in the app language', (
      tester,
    ) async {
      final rooms = _Rooms();
      addTearDown(rooms.close);
      await _open(tester, rooms, language: language);
      final field = find.byKey(const Key('room-name-field'));
      await tester.enterText(field, typed);
      await tester.pump();
      expect(
        tester.widget<TextField>(field).controller!.text,
        shown,
        reason: 'what the field shows is what it holds',
      );
      expect(
        find.descendant(of: field, matching: find.text(shown)),
        findsOneWidget,
      );
      // The counter counts in the same digits.
      final count = shown.length.toString();
      expect(
        find.text(localizeDigits('$count/48', farsi: language == 'fa')),
        findsOneWidget,
      );
      // Editing in the middle keeps the caret and converts the new digit.
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection.collapsed(offset: 1);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${shown.substring(0, 1)}9${shown.substring(1)}',
          selection: const TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      final nine = language == 'fa' ? '۹' : '9';
      expect(
        controller.text,
        '${shown.substring(0, 1)}$nine${shown.substring(1)}',
      );
      expect(controller.selection, const TextSelection.collapsed(offset: 2));
      // Validation still sees a name, and creation receives exactly it.
      await tester.tap(find.byKey(const Key('room-name-submit')));
      await tester.pump();
      expect(rooms.calls, 1);
      expect(rooms.name, controller.text.trim());
      rooms.creation.complete(null);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the lock-in builds the emblem and a tap goes straight on', (
    tester,
  ) async {
    final rooms = _Rooms();
    addTearDown(rooms.close);
    SavedRoom? returned;
    await _open(tester, rooms, onResult: (room) => returned = room);
    await _submit(tester, 'سفر');
    final room = _room('سفر');
    rooms.creation.complete(room);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Mid-sequence: the Room's initial has formed and its channel tag is up.
    expect(find.byKey(const Key('room-formation-emblem')), findsOneWidget);
    expect(find.byKey(const Key('room-create-channel-tag')), findsOneWidget);
    expect(find.text('اتاقت آماده‌ست'), findsWidgets);
    expect(returned, isNull);
    // A tap anywhere skips the rest of it.
    await tester.tap(find.byKey(const Key('room-create-skip')));
    await tester.pump();
    expect(returned, same(room));
    expect(rooms.calls, 1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RoomCreatePage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion confirms with a calm, complete frame', (
    tester,
  ) async {
    final rooms = _Rooms();
    addTearDown(rooms.close);
    SavedRoom? returned;
    await _open(
      tester,
      rooms,
      reduced: true,
      onResult: (room) => returned = room,
    );
    await _submit(tester, 'North');
    final room = _room('North');
    rooms.creation.complete(room);
    await tester.pump();
    await tester.pump();
    // The final frame immediately, nothing in flight.
    final emblem = find.byKey(const Key('room-formation-emblem'));
    expect(emblem, findsOneWidget);
    expect(_opacity(tester, emblem), 1);
    final tag = find.byKey(const Key('room-create-channel-tag'));
    expect(tag, findsOneWidget);
    expect(_opacity(tester, tag), 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(returned, isNull);
    await tester.pump(const Duration(milliseconds: 300));
    expect(returned, same(room));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'empty name is disabled, failure preserves the name and allows retry',
    (tester) async {
      final rooms = _Rooms();
      addTearDown(rooms.close);
      await _open(tester, rooms);
      final submit = find.descendant(
        of: find.byKey(const Key('room-name-submit')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('room-name-field')),
        '  سفر جمعه  ',
      );
      await tester.pump();
      await tester.tap(submit);
      await tester.pump();
      expect(rooms.calls, 1);
      expect(rooms.name, 'سفر جمعه');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      rooms.creation.complete(null);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-name-field')))
            .controller!
            .text,
        '  سفر جمعه  ',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('room-name-field')))
            .decoration!
            .errorText,
        isNotEmpty,
      );
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'creation waits for its ready animation and returns the created room once',
    (tester) async {
      final rooms = _Rooms();
      addTearDown(rooms.close);
      SavedRoom? returned;
      await _open(tester, rooms, onResult: (room) => returned = room);
      await tester.enterText(find.byKey(const Key('room-name-field')), 'سفر');
      await tester.pump();
      await tester.tap(find.byKey(const Key('room-name-submit')));
      await tester.pump();
      final now = DateTime.utc(2026, 10, 9);
      final room = SavedRoom(
        room: Room(
          id: RoomId('1' * 32),
          name: 'سفر',
          createdAt: now,
          updatedAt: now,
          members: const [],
        ),
        membership: RoomMembership(
          localMemberId: RoomMemberId('1' * 24),
          canManageInvites: true,
        ),
      );
      rooms.creation.complete(room);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(returned, isNull);
      expect(find.byType(RoomCreatePage), findsOneWidget);
      // The lock-in is a beat, never a wait: the hand-over lands inside the
      // 1.6s budget without anyone touching the screen.
      for (var ms = 700; ms < 1400 && returned == null; ms += 50) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(returned, same(room));
      expect(rooms.calls, 1);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RoomCreatePage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Persian large text and keyboard keep the name and action reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rooms = _Rooms();
      addTearDown(rooms.close);
      await _open(tester, rooms, scale: 1.5);
      tester.view.viewInsets = const FakeViewPadding(bottom: 230);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const Key('room-name-field')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byKey(const Key('room-name-field')), 'سفر');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('room-name-submit')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
