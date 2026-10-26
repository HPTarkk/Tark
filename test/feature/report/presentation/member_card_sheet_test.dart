import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/report/api/report_api.dart';
import 'package:tark/feature/report/presentation/widget/report_story_sheet.dart';

Widget _app(void Function(BuildContext) open) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        key: const Key('open'),
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  ),
);

MemberSubject _subject() => MemberSubject(
  name: 'Kian',
  seed: 'member-kian',
  avatar: (size) => SizedBox(width: size, height: size),
  roomId: 'room-1',
  roomName: 'Sunday ride',
  memberId: 'member-kian',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('mute on the card mutes them for this listener', (tester) async {
    final mutes = ListenerMutes();
    await tester.pumpWidget(
      _app(
        (context) => showMemberCard(context, subject: _subject(), mutes: mutes),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    expect(find.text('Kian'), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    await tester.tap(find.byKey(const Key('member-card-mute')));
    await tester.pumpAndSettle();
    expect(mutes.isMemberMuted('room-1', 'member-kian'), isTrue);

    await tester.tap(find.byKey(const Key('member-card-mute')));
    await tester.pumpAndSettle();
    expect(mutes.isMemberMuted('room-1', 'member-kian'), isFalse);
  });

  testWidgets('report on the card opens the report story', (tester) async {
    await tester.pumpWidget(
      _app(
        (context) => showMemberCard(
          context,
          subject: _subject(),
          mutes: ListenerMutes(),
          launchMail: (_) async => true,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('member-card-report')));
    await tester.pumpAndSettle();

    expect(find.byType(ReportStorySheet), findsOneWidget);
    expect(find.text('Did Kian spoil the ride?'), findsOneWidget);
  });

  testWidgets('a peer with no live sender and no Room has no mute', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        (context) => showMemberCard(
          context,
          subject: MemberSubject(
            name: 'Ghost',
            seed: 'g',
            avatar: (size) => SizedBox(width: size, height: size),
          ),
          mutes: ListenerMutes(),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('member-card-mute')), findsNothing);
    expect(find.byKey(const Key('member-card-report')), findsOneWidget);
  });
}
