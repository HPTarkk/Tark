import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

void main() {
  SavedRoom room() {
    final localId = RoomMemberId('111111111111111111111111');
    final peerId = RoomMemberId('222222222222222222222222');
    final now = DateTime.utc(2026, 8, 26, 18);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Night ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
          RoomMember(id: peerId, displayName: 'Rider two', joinedAt: now),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localId,
        canManageInvites: true,
      ),
    );
  }

  testWidgets('Persian lobby is RTL and fits a 320px viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var starts = 0;
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fa'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: room(),
          onStartRide: () => starts++,
          onBack: () => backs++,
        ),
      ),
    );
    // Bounded rather than pumpAndSettle: the Start ride action carries a
    // repeating pulse, and a settle waits for an animation that never ends.
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);
    // Persian numerals, not a Latin "2". A quantity rendered in ASCII digits
    // inside an otherwise Persian sentence is the most visible way this screen
    // can look half-translated.
    expect(find.text('اعضای اتاق (۲)'), findsOneWidget);
    expect(
      Directionality.of(
        tester.element(find.byKey(const Key('selected-room-lobby'))),
      ),
      TextDirection.rtl,
    );
    expect(tester.takeException(), isNull);

    // Start sits below Invite and can be under the fold.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    expect(starts, 1);

    // Creating a room replaces the route stack, so this screen is routinely
    // the only thing on it: without a control of its own there is no system
    // back to inherit and the gesture closed the app.
    await tester.dragUntilVisible(
      find.byKey(const Key('selected-room-lobby-back')),
      find.byKey(const Key('selected-room-lobby')),
      const Offset(0, 200),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-lobby-back')));
    expect(backs, 1);
    expect(find.byTooltip('بازگشت'), findsOneWidget);
  });

  testWidgets('English lobby exposes member names and explicit Start ride', (
    tester,
  ) async {
    var starts = 0;
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: room(),
          onStartRide: () => starts++,
          onBack: () => backs++,
        ),
      ),
    );
    // Bounded rather than pumpAndSettle: the Start ride action carries a
    // repeating pulse, and a settle waits for an animation that never ends.
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Room members (2)'), findsOneWidget);
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
    // Start sits below Invite and can be under the fold.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    expect(starts, 1);

    await tester.dragUntilVisible(
      find.byKey(const Key('selected-room-lobby-back')),
      find.byKey(const Key('selected-room-lobby')),
      const Offset(0, 200),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-lobby-back')));
    expect(backs, 1);
    expect(find.byTooltip('Back'), findsOneWidget);
  });

  group('the hint names what is on screen', () {
    Future<void> pumpLobby(
      WidgetTester tester, {
      required SavedRoom saved,
      VoidCallback? onConnect,
      Locale locale = const Locale('en'),
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SelectedRoomLobby(
            room: saved,
            onStartRide: () {},
            onBack: () {},
            onConnect: onConnect,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
    }

    SavedRoom alone() {
      final full = room();
      return SavedRoom(
        room: full.room.copyWith(members: [full.room.members.first]),
        membership: full.membership,
      );
    }

    testWidgets('Start ride is the button the hint mentions', (tester) async {
      await pumpLobby(tester, saved: room());
      expect(
        find.text('Your mic stays off until you press Start ride.'),
        findsOneWidget,
      );
    });

    testWidgets('when phones must connect first, the hint says so', (
      tester,
    ) async {
      await pumpLobby(tester, saved: room(), onConnect: () {});
      expect(
        find.text('Your mic stays off until you press Connect phones.'),
        findsOneWidget,
      );
      await pumpLobby(
        tester,
        saved: room(),
        onConnect: () {},
        locale: const Locale('fa'),
      );
      expect(
        find.text('تا «وصل کردن گوشی‌ها» رو نزنی، میکروفون خاموش می‌مونه.'),
        findsOneWidget,
      );
    });

    testWidgets('alone, no button is named and the heading is not stale', (
      tester,
    ) async {
      await pumpLobby(tester, saved: alone());
      expect(find.byKey(const Key('selected-room-start-ride')), findsNothing);
      expect(find.text('Just you so far'), findsOneWidget);
      expect(find.text('Invite someone to start talking.'), findsOneWidget);
      expect(find.textContaining('Room created'), findsNothing);
      expect(find.textContaining('Start ride'), findsNothing);
    });
  });
}
