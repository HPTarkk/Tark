import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/report/api/report_api.dart';
import 'package:tark/feature/report/presentation/widget/member_card_sheet.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

const _roomId = '0123456789abcdef0123456789abcdef';
const _peer = '222222222222222222222222';

SavedRoom _room() {
  const localId = RoomMemberId('111111111111111111111111');
  final now = DateTime.utc(2026, 8, 26, 18);
  return SavedRoom(
    room: Room(
      id: const RoomId(_roomId),
      name: 'Night ride',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
        RoomMember(
          id: const RoomMemberId(_peer),
          displayName: 'Rider two',
          joinedAt: now,
        ),
      ],
    ),
    membership: const RoomMembership(
      localMemberId: localId,
      canManageInvites: true,
    ),
  );
}

Future<void> _pumpLobby(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SelectedRoomLobby(room: _room(), onStartRide: () {}, onBack: () {}),
    ),
  );
  // Bounded: the Start ride action pulses forever.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(() => ReportConfig.debugOverride = true);
  tearDownAll(() => ReportConfig.debugOverride = null);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ListenerMutes.instance.resetForTest();
    MemberTapHint.instance.resetForTest();
  });
  tearDown(ListenerMutes.instance.resetForTest);

  testWidgets('tapping another member opens their card with Report', (
    tester,
  ) async {
    await _pumpLobby(tester);
    await tester.tap(find.text('Rider two'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(MemberCardSheet), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);

    await tester.tap(find.byKey(const Key('member-card-mute')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(ListenerMutes.instance.isMemberMuted(_roomId, _peer), isTrue);
  });

  testWidgets('your own row is not a profile you can report', (tester) async {
    await _pumpLobby(tester);
    await tester.tap(find.text('Rider one'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MemberCardSheet), findsNothing);
  });

  testWidgets('a muted member shows it on their lobby row', (tester) async {
    await ListenerMutes.instance.setMemberMuted(_roomId, _peer, true);
    await _pumpLobby(tester);
    expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
  });

  testWidgets(
    'with the build flag off, rows open nothing and mutes are inert',
    (tester) async {
      await ListenerMutes.instance.setMemberMuted(_roomId, _peer, true);
      ReportConfig.debugOverride = false;
      addTearDown(() => ReportConfig.debugOverride = true);

      await _pumpLobby(tester);
      expect(find.byIcon(Icons.volume_off_rounded), findsNothing);
      expect(ListenerMutes.instance.isMemberMuted(_roomId, _peer), isFalse);
      ListenerMutes.instance.bindSender(_roomId, _peer, 'sender');
      expect(ListenerMutes.instance.isSenderMuted('sender'), isFalse);

      await tester.tap(find.text('Rider two'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MemberCardSheet), findsNothing);
      expect(find.byKey(const Key('tap-coach-note')), findsNothing);
      expect(find.byKey(const Key('tap-coach-face')), findsNothing);
    },
  );

  group('the one-time tap coach', () {
    final note = find.byKey(const Key('tap-coach-note'));
    final face = find.byKey(const Key('tap-coach-face'));

    testWidgets('shows on the first other rider, never on your own row', (
      tester,
    ) async {
      await _pumpLobby(tester);
      expect(note, findsOneWidget);
      expect(face, findsOneWidget);
      expect(find.text('Tap anyone to mute or report them'), findsOneWidget);
      // It points at Rider two, the row right above it.
      final rowTwo = tester.getRect(find.text('Rider two'));
      final rowOne = tester.getRect(find.text('Rider one'));
      final callout = tester.getRect(note);
      expect(callout.top, greaterThan(rowTwo.bottom));
      expect(callout.top, greaterThan(rowOne.bottom));
    });

    testWidgets('opening a card retires it for good', (tester) async {
      await _pumpLobby(tester);
      await tester.tap(find.text('Rider two'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MemberCardSheet), findsOneWidget);
      expect(MemberTapHint.instance.showing, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('member_tap_hint.seen.v1'), isTrue);

      // A later visit: still learned.
      MemberTapHint.instance.resetForTest();
      await tester.pumpWidget(const SizedBox());
      await _pumpLobby(tester);
      expect(note, findsNothing);
      expect(face, findsNothing);
    });

    testWidgets('tapping the callout dismisses it', (tester) async {
      await _pumpLobby(tester);
      final words = find.text('Tap anyone to mute or report them');
      await tester.ensureVisible(words);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(words);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(note, findsNothing);
      expect(MemberTapHint.instance.showing, isFalse);
    });

    testWidgets('after its moment on screen it goes away by itself', (
      tester,
    ) async {
      await _pumpLobby(tester);
      expect(note, findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(milliseconds: 600));
      expect(note, findsNothing);
      expect(face, findsNothing);
    });

    testWidgets('holds still under reduced motion', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: SelectedRoomLobby(
            room: _room(),
            onStartRide: () {},
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(note, findsOneWidget);
      final scale = tester.widget<Transform>(
        find.descendant(of: face, matching: find.byType(Transform)).first,
      );
      expect(scale.transform.getMaxScaleOnAxis(), 1);
    });
  });
}
