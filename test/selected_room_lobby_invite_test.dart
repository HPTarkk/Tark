import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

void main() {
  late SharedPreferencesRoomRepository repository;
  final at = DateTime.utc(2026, 9, 5);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  Future<SavedRoom> seat(
    SavedRoom room, {
    required bool pending,
    String name = 'Rider two',
  }) async {
    final invite = await repository.issueInvite(
      room.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: at,
      ttl: const Duration(hours: 12),
    );
    final verified = await repository.verifyAndRedeemInvite(invite, now: at);
    return repository.acceptVerifiedInvite(
      verified!,
      displayName: name,
      acceptedAt: at,
      pending: pending,
    );
  }

  Widget host(SavedRoom room, {Locale locale = const Locale('en')}) =>
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SelectedRoomLobby(
          room: room,
          repository: repository,
          onStartRide: () {},
          onBack: () {},
        ),
      );

  Future<void> show(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('one confirmed member stays a one-person Room', (tester) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );

    await show(tester, host(room));

    expect(find.text('Room members (1)'), findsOneWidget);
    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-held-seats')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unused invite seat is invisible to member count and roster', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );

    await show(tester, host(room));
    await seat(room, pending: true, name: 'Open seat');
    await beat(tester);

    expect(find.text('Room members (1)'), findsOneWidget);
    expect(find.text('Room members (2)'), findsNothing);
    expect(find.text('Open seat'), findsNothing);
    expect(find.byKey(const Key('selected-room-held-seats')), findsNothing);
    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed rider appears as a real second member', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final withRider = await seat(room, pending: false);

    await show(tester, host(withRider));

    expect(find.text('Room members (2)'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
    expect(find.byKey(const Key('selected-room-held-seats')), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('member without invite authority has no dead invite action', (
    tester,
  ) async {
    final created = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final guest = SavedRoom(
      room: created.room,
      membership: RoomMembership(
        localMemberId: created.membership.localMemberId,
        canManageInvites: false,
      ),
    );

    await show(tester, host(guest));

    expect(find.byKey(const Key('selected-room-invite-callout')), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Persian confirmed member count remains RTL and localized', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'شب‌گردی',
      localDisplayName: 'میزبان',
    );
    final withRider = await seat(room, pending: false, name: 'همراه');

    await show(tester, host(withRider, locale: const Locale('fa')));

    final count = find.text('اعضای اتاق (۲)');
    expect(count, findsOneWidget);
    expect(Directionality.of(tester.element(count)), TextDirection.rtl);
    expect(find.byKey(const Key('selected-room-held-seats')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
