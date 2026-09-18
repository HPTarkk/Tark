import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/core/recovery/recovery_sheet.dart';
import 'package:tark/core/widget/localized_counter.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

/// Persian renders its own numerals. A Latin `5` inside an otherwise Persian
/// sentence is the most visible way an app can look half-translated, and it is
/// the easiest thing in the world to reintroduce — every new `'$count'` is a
/// chance to forget.
///
/// These render the surfaces that actually carry numbers under `fa` and assert
/// no ASCII digit reaches the screen.
void main() {
  /// Every ASCII digit found in the rendered tree.
  ///
  /// Walks `Text` widgets rather than inspecting strings, so it catches a
  /// number no matter which layer forgot to convert it.
  List<String> latinDigitsOnScreen(WidgetTester tester) {
    final offenders = <String>[];
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final value = text.data ?? text.textSpan?.toPlainText() ?? '';
      if (RegExp(r'[0-9]').hasMatch(value)) offenders.add(value);
    }
    return offenders;
  }

  Widget fa(Widget child) => MaterialApp(
    locale: const Locale('fa'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: child),
  );

  Widget en(Widget child) => MaterialApp(
    locale: const Locale('en'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: child),
  );

  Widget countedField() => TextField(
    controller: TextEditingController(text: 'ali'),
    maxLength: 12,
    buildCounter: localizedCounter(),
  );

  // R30. The one number on screen that no sweep over this repository could
  // ever have found: Flutter builds `'$currentLength/$maxLength'` itself, with
  // bare interpolation, inside `TextField._getEffectiveDecoration`. The only
  // way in is `buildCounter`.
  testWidgets('a field counts its own characters in Persian', (tester) async {
    await tester.pumpWidget(fa(countedField()));

    expect(latinDigitsOnScreen(tester), isEmpty);
    expect(find.text('۳/۱۲'), findsOneWidget);
  });

  testWidgets('and still counts in Latin under English', (tester) async {
    await tester.pumpWidget(en(countedField()));

    expect(find.text('3/12'), findsOneWidget);
  });

  testWidgets('the counter reads current-then-limit, not reversed', (
    tester,
  ) async {
    await tester.pumpWidget(fa(countedField()));

    // Persian writes numbers left-to-right inside right-to-left text. Left to
    // the paragraph's own direction, «۳/۱۲» is free to come out as «۱۲/۳» — a
    // counter that reads as though the field were already over its limit.
    final counter = tester.widget<Text>(find.text('۳/۱۲'));
    expect(counter.textDirection, TextDirection.ltr);
  });

  testWidgets('a screen reader is still told what is left', (tester) async {
    await tester.pumpWidget(fa(countedField()));

    // Supplying `buildCounter` makes the framework return before it sets
    // `semanticCounterText`, so the naive fix silently drops this. The label
    // is the same MaterialLocalizations sentence it would have used.
    final counter = tester.widget<Text>(find.text('۳/۱۲'));
    expect(counter.semanticsLabel, isNotNull);
    expect(counter.semanticsLabel, isNot(contains('/')));
  });

  testWidgets('a field with no limit still has no counter', (tester) async {
    await tester.pumpWidget(
      fa(
        TextField(
          controller: TextEditingController(text: 'ali'),
          buildCounter: localizedCounter(),
        ),
      ),
    );

    expect(latinDigitsOnScreen(tester), isEmpty);
  });

  testWidgets('numbered instruction bullets use Persian numerals', (
    tester,
  ) async {
    await tester.pumpWidget(
      fa(
        const Column(
          children: [
            StepRow(index: 1, icon: Icons.wifi, text: 'یک'),
            StepRow(index: 2, icon: Icons.wifi, text: 'دو'),
            StepRow(index: 10, icon: Icons.wifi, text: 'ده'),
          ],
        ),
      ),
    );

    expect(latinDigitsOnScreen(tester), isEmpty);
    expect(find.text('۱'), findsOneWidget);
    expect(find.text('۱۰'), findsOneWidget);
  });

  testWidgets('the troubleshooting sheet counts in Persian numerals', (
    tester,
  ) async {
    // The ratio pill ("2 / 5") is the one number on this sheet, and it only
    // appears when something is wrong — which is exactly when nobody is in the
    // mood to decode a half-translated interface.
    await tester.pumpWidget(
      fa(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showRecoverySheet(
              context,
              initial: const [
                RecoveryCheck(
                  label: 'میکروفن',
                  detail: 'اجازه داده نشده',
                  status: RecoveryStatus.bad,
                ),
                RecoveryCheck(
                  label: 'شبکه',
                  detail: 'وصل',
                  status: RecoveryStatus.ok,
                ),
                RecoveryCheck(
                  label: 'صدا',
                  detail: 'خوب',
                  status: RecoveryStatus.ok,
                ),
              ],
              checks: const Stream<List<RecoveryCheck>>.empty(),
            ),
            child: const Text('باز کن'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('باز کن'));
    await tester.pumpAndSettle();

    expect(latinDigitsOnScreen(tester), isEmpty);
    expect(find.text('۱ / ۳'), findsOneWidget);
  });

  testWidgets('the Room lobby counts its members in Persian numerals', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 9, 1);
    final members = [
      for (var i = 0; i < 3; i++)
        RoomMember(
          id: RoomMemberId('$i'.padLeft(24, 'a')),
          displayName: 'همراه',
          joinedAt: now,
        ),
    ];

    await tester.pumpWidget(
      fa(
        SelectedRoomLobby(
          room: SavedRoom(
            room: Room(
              id: RoomId('a' * 32),
              name: 'گروه جمعه',
              createdAt: now,
              updatedAt: now,
              members: members,
            ),
            membership: RoomMembership(
              localMemberId: members.first.id,
              canManageInvites: true,
            ),
          ),
          onStartRide: () {},
          onBack: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));

    expect(latinDigitsOnScreen(tester), isEmpty);
    expect(find.textContaining('۳'), findsOneWidget);
  });
}
