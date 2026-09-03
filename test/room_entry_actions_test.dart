import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/theme/app_colors.dart';
import 'package:tark/feature/landing/presentation/widget/room_entry_actions.dart';

/// Landing's entry options, which used to be a flat `List` plus a `primary`
/// bool — a shape that can only express a binary. One loud card over two
/// identical quiet ones is a list with a highlight on it, and it was why
/// nothing on the screen said which thing to press.
void main() {
  var joins = 0;
  var creates = 0;
  var resumes = 0;
  var browses = 0;

  setUp(() {
    joins = creates = resumes = browses = 0;
  });

  Widget host(Widget child, {Locale locale = const Locale('en')}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Center(child: child),
          ),
        ),
      );

  RoomEntryActions returning({required bool fa}) => RoomEntryActions(
    hero: RoomEntryAction(
      key: const Key('landing-resume-room'),
      icon: Icons.meeting_room_rounded,
      monogram: fa ? 'شب‌گردی' : 'Night ride',
      label: fa ? 'شب‌گردی' : 'Night ride',
      hint: fa ? 'ادامه در این اتاق' : 'Pick up where you left off',
      variant: RoomEntryVariant.hero,
      onTap: () => resumes++,
    ),
    alternatives: [
      RoomEntryAction(
        key: const Key('landing-join-room'),
        icon: Icons.qr_code_scanner_rounded,
        label: fa ? 'پیوستن' : 'JOIN',
        hint: fa ? 'کد میزبان را اسکن کن' : "Scan a host's code",
        variant: RoomEntryVariant.compact,
        onTap: () => joins++,
      ),
      RoomEntryAction(
        key: const Key('landing-create-room'),
        icon: Icons.add_rounded,
        label: fa ? 'اتاق تازه' : 'NEW ROOM',
        hint: fa ? 'خودت یکی بساز' : 'Start your own',
        variant: RoomEntryVariant.compact,
        onTap: () => creates++,
      ),
    ],
    browse: RoomBrowseLink(
      key: const Key('landing-all-rooms'),
      label: fa ? 'اتاق‌های من' : 'MY ROOMS',
      count: fa ? '۳' : '3',
      onTap: () => browses++,
    ),
  );

  /// The hero breathes, so a settle never returns.
  Future<void> beat(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 300));

  testWidgets('three tiers fit a 320px screen in both languages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final locale in [const Locale('en'), const Locale('fa')]) {
      final fa = locale.languageCode == 'fa';
      await tester.pumpWidget(host(returning(fa: fa), locale: locale));
      await beat(tester);

      // A pair of half-width cards is where this could overflow: 320 less the
      // page's 24 either side and a 12 gap leaves 130 each, and Persian labels
      // are not shorter than English ones.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('landing-resume-room')), findsOneWidget);
      expect(find.byKey(const Key('landing-join-room')), findsOneWidget);
      expect(find.byKey(const Key('landing-create-room')), findsOneWidget);
      expect(find.byKey(const Key('landing-all-rooms')), findsOneWidget);
    }
  });

  testWidgets('creating a room is an option, not a line of hint text', (
    tester,
  ) async {
    await tester.pumpWidget(host(returning(fa: false)));
    await beat(tester);

    // The whole of the reported problem: this used to exist only inside MY
    // ROOMS' subtitle, which is the weakest place on the screen for the
    // second-most-likely action.
    await tester.tap(find.byKey(const Key('landing-create-room')));
    expect(creates, 1);

    await tester.tap(find.byKey(const Key('landing-join-room')));
    await tester.tap(find.byKey(const Key('landing-resume-room')));
    await tester.tap(find.byKey(const Key('landing-all-rooms')));
    expect((joins, resumes, browses), (1, 1, 1));
  });

  testWidgets('the pair are equals, and both are quieter than the hero', (
    tester,
  ) async {
    await tester.pumpWidget(host(returning(fa: false)));
    await beat(tester);

    BoxDecoration shellOf(Key key) {
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byKey(key),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return box.decoration as BoxDecoration;
    }

    final hero = shellOf(const Key('landing-resume-room'));
    final join = shellOf(const Key('landing-join-room'));
    final create = shellOf(const Key('landing-create-room'));

    // Weight, not colour: the hero is the only thing wearing a fill, a 2px
    // border and a glow.
    expect(hero.border!.top.width, 2);
    expect(hero.boxShadow, isNotNull);
    for (final quiet in [join, create]) {
      expect(quiet.border!.top.width, 1);
      expect(quiet.boxShadow, isNull);
      expect(quiet.color, AppColors.card);
    }
    // And the pair are drawn identically, because they really are peers —
    // which is exactly what the third tier is for saying about MY ROOMS.
    expect(join.color, create.color);
    expect(join.border, create.border);
  });

  testWidgets('browsing the list is not drawn as a fourth card', (
    tester,
  ) async {
    await tester.pumpWidget(host(returning(fa: false)));
    await beat(tester);

    // Navigation, not an action. Giving it a card is what made three options
    // read as three peers.
    expect(
      find.descendant(
        of: find.byKey(const Key('landing-all-rooms')),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('a first run keeps two full-width rows', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      host(
        RoomEntryActions(
          hero: RoomEntryAction(
            key: const Key('landing-create-room'),
            icon: Icons.add_home_work_outlined,
            label: 'CREATE ROOM',
            hint: 'Start one and invite the others',
            variant: RoomEntryVariant.hero,
            onTap: () => creates++,
          ),
          alternatives: [
            RoomEntryAction(
              key: const Key('landing-join-room'),
              icon: Icons.qr_code_scanner_rounded,
              label: 'JOIN WITH QR',
              hint: "Scan the code on the host's phone",
              variant: RoomEntryVariant.wide,
              onTap: () => joins++,
            ),
          ],
        ),
      ),
    );
    await beat(tester);

    // Two options is not a list, so halving their width would only make them
    // harder to hit for nothing. They stay full-bleed, and there is no list to
    // browse yet.
    final create = tester.getSize(find.byKey(const Key('landing-create-room')));
    final join = tester.getSize(find.byKey(const Key('landing-join-room')));
    expect(join.width, create.width);
    expect(find.byType(RoomBrowseLink), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion stills the hero without flattening it', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: returning(fa: false)),
        ),
      ),
    );
    // No repeating animation left, so this must be able to settle.
    await tester.pumpAndSettle();

    final hero =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(const Key('landing-resume-room')),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    // Still the hero — the weight is what carries the hierarchy, and only the
    // breathing is dropped.
    expect(hero.border!.top.width, 2);
    expect(hero.boxShadow, isNotNull);
  });
}
