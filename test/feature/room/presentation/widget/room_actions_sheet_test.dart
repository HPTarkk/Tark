import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/presentation/widget/room_actions_sheet.dart';

Widget _app({
  required ValueChanged<RoomAction?> onResult,
  bool archived = false,
  bool reduced = false,
}) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        child: const Text('open'),
        onPressed: () async => onResult(
          await showRoomActionsSheet(
            context,
            roomName: 'Northbound',
            archived: archived,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  for (final action in RoomAction.values) {
    testWidgets('${action.name} returns once after the panel has left', (
      tester,
    ) async {
      final results = <RoomAction?>[];
      await tester.pumpWidget(_app(onResult: results.add));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Northbound'), findsOneWidget);
      await tester.tap(find.byKey(Key('room-action-${action.name}')));
      await tester.pump();
      expect(results, isEmpty);
      await tester.pumpAndSettle();
      expect(results, [action]);
      expect(find.byKey(const Key('room-actions-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final dismissal in ['close', 'back', 'scrim']) {
    testWidgets('$dismissal cancels without choosing a room action', (
      tester,
    ) async {
      final results = <RoomAction?>[];
      await tester.pumpWidget(_app(onResult: results.add));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      switch (dismissal) {
        case 'close':
          await tester.tap(find.byKey(const Key('room-actions-close')));
        case 'back':
          await tester.binding.handlePopRoute();
        case 'scrim':
          await tester.tapAt(const Offset(20, 20));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(find.byKey(const Key('room-actions-sheet')), findsNothing);
    });
  }
  testWidgets('archived room omits archive and reduced motion completes', (
    tester,
  ) async {
    final results = <RoomAction?>[];
    await tester.pumpWidget(
      _app(onResult: results.add, archived: true, reduced: true),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('room-action-archive')), findsNothing);
    await tester.tap(find.byKey(const Key('room-action-rename')));
    await tester.pumpAndSettle();
    expect(results, [RoomAction.rename]);
    expect(tester.takeException(), isNull);
  });
}
