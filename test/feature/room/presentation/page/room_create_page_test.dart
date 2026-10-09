import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/l10n/app_localizations.dart';
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
  ValueChanged<SavedRoom?>? onResult,
}) => MaterialApp(
  locale: const Locale('fa'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
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
  ValueChanged<SavedRoom?>? onResult,
}) async {
  await tester.pumpWidget(_app(rooms, scale: scale, onResult: onResult));
  await tester.tap(find.text('open'));
  await tester.pump();
  for (var i = 0; i < 36; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  tearDown(() => GetIt.instance.reset());
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
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(returned, same(room));
      expect(rooms.calls, 1);
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
