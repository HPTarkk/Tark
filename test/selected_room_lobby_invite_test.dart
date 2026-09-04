import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';

/// The lobby is where creating a room lands you, and the only way to put a
/// second person in it used to be one pill in the app bar — a place you find by
/// looking rather than by reading. A room with one person in it is not a room
/// yet, so that case now says so and offers the single thing that fixes it, in
/// the shape the empty saved-rooms list already uses.
void main() {
  late SharedPreferencesRoomRepository repository;
  final at = DateTime.utc(2026, 9, 2);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = SharedPreferencesRoomRepository();
  });

  /// Exactly what the People sheet does when the host asks for a code.
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
        // The app's own delegate, not just the Material ones: the lobby reads
        // its copy from [AppLocalizations] now rather than switching on the
        // locale itself, so a harness without it has no strings at all.
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: SelectedRoomLobby(
          room: room,
          repository: repository,
          onStartRide: () {},
          onBack: () {},
        ),
      );

  /// Bounded, never `pumpAndSettle`: the lit action pulses forever, so settling
  /// has no end to reach.
  Future<void> show(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  Future<void> beat(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// Whether the control under [key] is the one the screen is pointing at.
  bool lit(WidgetTester tester, Key key) => tester
      .widgetList<PulseGlow>(
        find.descendant(of: find.byKey(key), matching: find.byType(PulseGlow)),
      )
      .any((glow) => glow.enabled);

  testWidgets('a room with only you leads with the invite, not the ride', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );

    await show(tester, host(room));

    expect(find.text('Your room is ready'), findsOneWidget);
    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );
    expect(find.text("You're the only one here"), findsOneWidget);
    expect(find.text('INVITE SOMEONE'), findsOneWidget);

    // Starting alone stays possible — it is what brings the hotspot up — but
    // it is no longer what the screen is pointing at.
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(
      find.text('Or start now and invite once you are on the air.'),
      findsOneWidget,
    );
    expect(lit(tester, const Key('selected-room-invite')), isTrue);
    expect(lit(tester, const Key('selected-room-start-ride')), isFalse);

    // No roster: one row that says "You" is not information.
    expect(find.text('Room members (1)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second person turns the ride back into the point', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    final withRider = await seat(room, pending: false);

    await show(tester, host(withRider));

    expect(find.text('Ready to start'), findsOneWidget);
    expect(find.text('Room members (2)'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
    expect(find.byKey(const Key('selected-room-invite-callout')), findsNothing);
    // Still reachable without hunting through the app bar, just no longer the
    // lead.
    expect(find.text('INVITE SOMEONE ELSE'), findsOneWidget);
    expect(lit(tester, const Key('selected-room-start-ride')), isTrue);
    expect(lit(tester, const Key('selected-room-invite')), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invite made while the lobby is open shows up on it', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );

    await show(tester, host(room));
    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );

    // A durable seat nobody is standing in yet. The lobby was handed its Room
    // once and would otherwise go on saying the host is alone.
    await seat(room, pending: true, name: 'Open seat');
    await beat(tester);

    expect(find.byKey(const Key('selected-room-invite-callout')), findsNothing);
    expect(find.byKey(const Key('selected-room-held-seats')), findsOneWidget);
    expect(find.text('Waiting to join (1)'), findsOneWidget);
    expect(
      find.text('They have a code but have not scanned it yet.'),
      findsOneWidget,
    );
    // A held seat is never counted as a member — that is how two phones came
    // to disagree about how many people were in a room.
    expect(find.text('Room members (1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without the invite right the callout offers no dead control', (
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

    expect(
      find.byKey(const Key('selected-room-invite-callout')),
      findsOneWidget,
    );
    expect(
      find.text(
        'Nobody else is here yet. Adding people is up to whoever runs this '
        'room.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-room-invite')), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Persian reads right to left, with Persian counts', (
    tester,
  ) async {
    final room = await repository.create(
      name: 'شب‌گردی',
      localDisplayName: 'میزبان',
    );
    final withRider = await seat(room, pending: false, name: 'همراه');

    await show(tester, host(withRider, locale: const Locale('fa')));

    expect(find.text('اعضای اتاق (۲)'), findsOneWidget);
    expect(find.text('دعوت کسی دیگر'), findsOneWidget);
    final heading = tester.element(find.text('آماده شروع ارتباط'));
    expect(Directionality.of(heading), TextDirection.rtl);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the alone state is Persian too', (tester) async {
    final room = await repository.create(
      name: 'شب‌گردی',
      localDisplayName: 'میزبان',
    );

    await show(tester, host(room, locale: const Locale('fa')));

    expect(find.text('اتاق ساخته شد'), findsOneWidget);
    expect(find.text('هنوز تنها هستید'), findsOneWidget);
    expect(find.text('دعوت کردن'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
