import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/router/app_router.dart';
import 'package:tark/core/config/onboarding_config.dart';
import 'package:tark/core/config/quick_access_config.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/locale/locale_service.dart';
import 'package:tark/core/motion/continuity_route.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/core/widget/theme_toggle.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/onboarding/presentation/page/onboarding_page.dart';
import 'package:tark/feature/onboarding/presentation/widget/onboarding_controls.dart';
import 'package:tark/feature/onboarding/presentation/widget/onboarding_movements.dart';
import 'package:tark/feature/onboarding/presentation/widget/onboarding_stage.dart';
import 'package:tark/feature/room/api/room_api.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_create_page.dart';
import 'package:tark/feature/room/presentation/widget/room_visuals.dart';
import 'package:tark/feature/transfer/data/service/session_role_store_impl.dart';
import 'package:tark/feature/transfer/data/service/transfer_mode_store_impl.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

class _Unlocked implements LicenseGate {
  @override
  bool allows(PremiumFeature feature) => true;
  @override
  bool get canPurchase => false;
  @override
  Stream<void> get changes => const Stream.empty();
}

/// Just enough Room storage for the creation screen to open: no Rooms yet.
class _NoRooms implements RoomRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => [];

  @override
  Future<RoomId?> selectedRoomId() async => null;

  @override
  Future<void> select(RoomId? id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Journey {
  _Journey(this.prefs, this.modes, this.router);

  final SharedPreferences prefs;
  final TransferModeStoreImpl modes;
  final GoRouter router;

  OnboardingCubit cubit(WidgetTester tester) =>
      tester.element(find.byType(OnboardingPage)).read<OnboardingCubit>();

  AppLocalizations strings(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(OnboardingPage)))!;

  /// Where the route showing [finder] was opened — pushed routes included.
  Uri locationOf(WidgetTester tester, Finder finder) =>
      GoRouterState.of(tester.element(finder)).uri;

  static Future<_Journey> start(
    WidgetTester tester, {
    bool reduced = false,
    bool replay = false,
    int initialStep = 0,
    String? initialName,
    Map<String, Object> saved = const {},
    Size size = const Size(400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      SettingsKeys.userName: '',
      SettingsKeys.appLocale: 'en',
      SettingsKeys.appTheme: 'dark',
      ...saved,
    });
    final prefs = await SharedPreferences.getInstance();
    LocaleService.initialize(prefs);
    ThemeService.initialize(prefs);
    final modes = TransferModeStoreImpl(
      prefs,
      SessionRoleStoreImpl(),
      _Unlocked(),
    );
    await modes.initialize();
    final settings = SettingsRepositoryImpl(prefs);
    GetIt.instance
      ..registerSingleton<LicenseGate>(_Unlocked())
      ..registerFactory<OnboardingCubit>(() => OnboardingCubit(modes, settings))
      ..registerFactory<RoomListCubit>(() => RoomListCubit(_NoRooms()));
    // The Room routes are built exactly as the app builds them — through
    // AppRouter.pageFor, so a ContinuityHandoff makes them continuations.
    final router = GoRouter(
      initialLocation: replay
          ? AppRoutes.settingsPath
          : AppRoutes.onboardingPath,
      routes: [
        GoRoute(
          path: AppRoutes.onboardingPath,
          builder: (_, _) => OnboardingPage.buildPage(
            replay: replay,
            initialStep: initialStep,
            initialName: initialName,
          ),
        ),
        GoRoute(
          path: AppRoutes.landingPath,
          pageBuilder: (_, state) => AppRouter.pageFor(
            state,
            const Scaffold(body: Text('Lobby reached')),
          ),
        ),
        GoRoute(
          path: AppRoutes.roomsPath,
          pageBuilder: (_, state) => AppRouter.pageFor(
            state,
            RoomManagerEntry.buildPage(
              createOnOpen: state.uri.queryParameters['create'] == 'true',
              initialName: state.uri.queryParameters['name'],
              continuous: state.extra is ContinuityHandoff,
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.roomQrJoinPath,
          pageBuilder: (_, state) => AppRouter.pageFor(
            state,
            const Scaffold(body: Text('Scanner open')),
          ),
        ),
        GoRoute(
          path: AppRoutes.settingsPath,
          builder: (_, _) => const Scaffold(body: Text('Settings restored')),
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
      await GetIt.instance.reset();
    });
    await tester.pumpWidget(
      ValueListenableBuilder<Locale>(
        valueListenable: LocaleService.locale,
        builder: (_, locale, _) => MaterialApp.router(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
        ),
      ),
    );
    if (replay) {
      router.push(AppRoutes.onboardingPath);
      await tester.pump();
    }
    await _settle(tester);
    return _Journey(prefs, modes, router);
  }
}

/// Lets every choreography in flight (the beacon's spring, the line
/// hand-over, a continuity page) run to rest. Several pumps rather than one
/// long one: some motion only starts once an earlier one is under way.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _settle(tester);
}

/// Swipes the face strip until [id] is on screen, then picks it.
Future<void> _pickAvatar(WidgetTester tester, int id) async {
  final face = find.byKey(ValueKey('avatar-$id'));
  await tester.scrollUntilVisible(
    face,
    80,
    scrollable: find.descendant(
      of: find.byType(AvatarStrip),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.ensureVisible(face);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(face);
  await _settle(tester);
}

Finder get _primary => find.byKey(const Key('onboarding-primary'));

OnboardingPrimaryButton _primaryButton(WidgetTester tester) =>
    tester.widget<OnboardingPrimaryButton>(_primary);

void main() {
  testWidgets('first run applies the look live and persists the rest only '
      'at the end', (tester) async {
    final journey = await _Journey.start(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.helloStep);
    expect(find.byType(OnboardingStage), findsOneWidget);

    // Language and theme switch live, through the same controls Settings
    // uses — and the cubit follows the theme so finishing never undoes it.
    await _tap(tester, find.text('فارسی'));
    expect(LocaleService.currentLocale, const Locale('fa'));
    expect(journey.prefs.getString(SettingsKeys.appLocale), 'fa');
    await _tap(tester, find.text('English'));
    expect(LocaleService.currentLocale, const Locale('en'));
    await _tap(tester, find.byType(ThemeToggle));
    expect(ThemeService.currentMode, AppThemeMode.light);
    expect(journey.cubit(tester).state.themePref, AppThemeMode.light);
    await _tap(tester, find.byType(ThemeToggle));
    expect(ThemeService.currentMode, AppThemeMode.dark);
    expect(journey.cubit(tester).state.themePref, AppThemeMode.dark);

    final s = journey.strings(tester);
    expect(_primaryButton(tester).label, s.onboarding_begin);
    await _tap(tester, _primary);
    expect(journey.cubit(tester).state.step, OnboardingCubit.identityStep);

    // The callsign gates the key; a blank one cannot be submitted.
    expect(_primaryButton(tester).enabled, isFalse);
    expect(_primaryButton(tester).label, s.onboarding_continue);
    final field = find.byKey(const Key('onboarding-callsign-field'));
    await tester.enterText(field, '   ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.identityStep);

    // The dice rolls a handle for anyone who would rather not choose.
    await _tap(tester, find.byKey(const Key('onboarding-shuffle')));
    expect(journey.cubit(tester).state.name.trim(), isNotEmpty);
    expect(_primaryButton(tester).enabled, isTrue);

    await tester.enterText(field, '  Trail rider  ');
    await tester.pump();
    await _pickAvatar(tester, 5);
    expect(journey.cubit(tester).state.avatarId, 5);
    expect(journey.prefs.getString(SettingsKeys.userName), '');
    expect(journey.prefs.getInt(SettingsKeys.avatarId), isNull);

    // Back and forth keeps the draft.
    await _tap(tester, find.byKey(const Key('onboarding-back')));
    expect(journey.cubit(tester).state.step, OnboardingCubit.helloStep);
    await _tap(tester, _primary);
    expect(tester.widget<TextField>(field).controller!.text, '  Trail rider  ');
    expect(journey.cubit(tester).state.avatarId, 5);

    // Done on the keyboard moves on, like the key.
    await tester.showKeyboard(field);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.roomStep);
    expect(find.byKey(const Key('onboarding-create-room')), findsOneWidget);
    expect(find.byKey(const Key('onboarding-join-room')), findsOneWidget);
    expect(find.byKey(const Key('onboarding-later')), findsOneWidget);
    expect(
      find.byKey(const Key('onboarding-skip')).hitTestable(),
      findsNothing,
    );
    expect(
      find.text(s.onbx_room_kicker('Trail rider').toUpperCase()),
      findsOneWidget,
    );

    // The connection is a quiet chip; changing it is a sheet away.
    await _tap(tester, find.byKey(const Key('onboarding-connection')));
    await _tap(tester, find.byKey(const ValueKey('connection-bluetooth')));
    expect(journey.cubit(tester).state.mode, TransferMode.bluetooth);
    expect(journey.modes.pinnedMode, isNull);
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isNull);

    // "Later" saves everything and hands over to Landing as a continuation.
    await _tap(tester, find.byKey(const Key('onboarding-later')));
    expect(find.text('Lobby reached'), findsOneWidget);
    final lobby = ModalRoute.of(tester.element(find.text('Lobby reached')))!;
    expect(lobby.settings, isA<ContinuityPage<void>>());
    expect(journey.prefs.getString(SettingsKeys.userName), 'Trail rider');
    expect(journey.prefs.getInt(SettingsKeys.avatarId), 5);
    expect(journey.prefs.getString(SettingsKeys.transportPin), 'bluetooth');
    expect(journey.prefs.getString(SettingsKeys.appTheme), 'dark');
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(
      journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
      isFalse,
    );
  });

  testWidgets('create continues into room creation with a suggested name, '
      'and backing out returns to the last step', (tester) async {
    final journey = await _Journey.start(
      tester,
      initialStep: OnboardingCubit.roomStep,
      initialName: 'Trail rider',
    );
    expect(find.byType(Hero), findsOneWidget);
    await _tap(tester, find.byKey(const Key('onboarding-create-room')));

    // Everything is saved before the Room flow starts, and the first-run
    // flags are those Landing's own entry points leave behind.
    expect(journey.prefs.getString(SettingsKeys.userName), 'Trail rider');
    expect(journey.prefs.getString(SettingsKeys.transportPin), 'wifi');
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore), isTrue);

    expect(find.byType(RoomCreatePage), findsOneWidget);
    expect(
      journey.locationOf(tester, find.byType(RoomCreatePage)).queryParameters,
      {'create': 'true', 'name': "Trail rider's crew"},
    );
    final create = tester.widget<RoomCreatePage>(find.byType(RoomCreatePage));
    expect(create.continuous, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('room-name-field')))
          .controller!
          .text,
      "Trail rider's crew",
    );
    // One tap is all it takes: the suggested name already enables Create.
    expect(
      tester
          .widget<RoomConnectButton>(find.byKey(const Key('room-name-submit')))
          .onTap,
      isNotNull,
    );
    expect(
      ModalRoute.of(tester.element(find.byType(RoomCreatePage)))!.settings,
      isA<ContinuityPage<void>>(),
    );
    // The formation the user saw is the one that landed here.
    final hero = tester.widget<Hero>(
      find.descendant(
        of: find.byType(RoomCreatePage),
        matching: find.byType(Hero),
      ),
    );
    expect(hero.tag, roomFormationHeroTag);

    // Back returns to the last movement, where every choice is still open.
    journey.router.pop();
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.roomStep);
    await _tap(tester, find.byKey(const Key('onboarding-later')));
    expect(find.text('Lobby reached'), findsOneWidget);
  });

  testWidgets('join continues into the invite scanner', (tester) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.roomStep,
      initialName: 'Scanner',
      saved: {SettingsKeys.avatarId: 7},
    );
    await _tap(tester, find.byKey(const Key('onboarding-join-room')));
    expect(find.text('Scanner open'), findsOneWidget);
    expect(
      journey.locationOf(tester, find.text('Scanner open')).path,
      AppRoutes.roomQrJoinPath,
    );
    expect(
      ModalRoute.of(tester.element(find.text('Scanner open')))!.settings,
      isA<ContinuityPage<void>>(),
    );
    expect(journey.prefs.getString(SettingsKeys.userName), 'Scanner');
    expect(journey.prefs.getInt(SettingsKeys.avatarId), 7);
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore), isTrue);

    journey.router.pop();
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.roomStep);
    // Coming back re-arms the actions.
    await _tap(tester, find.byKey(const Key('onboarding-join-room')));
    expect(find.text('Scanner open'), findsOneWidget);
  });

  testWidgets('skip discards draft profile and connection edits', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.identityStep,
      saved: {
        SettingsKeys.userName: 'Saved rider',
        SettingsKeys.avatarId: 3,
        SettingsKeys.transportPin: 'bluetooth',
        SettingsKeys.transportMode: 'bluetooth',
      },
    );
    await tester.enterText(
      find.byKey(const Key('onboarding-callsign-field')),
      'Discard this draft',
    );
    await _tap(tester, find.byKey(const Key('onboarding-skip')));
    expect(find.text('Lobby reached'), findsOneWidget);
    expect(journey.prefs.getString(SettingsKeys.userName), 'Saved rider');
    expect(journey.prefs.getInt(SettingsKeys.avatarId), 3);
    expect(journey.modes.pinnedMode, TransferMode.bluetooth);
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(
      journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
      isFalse,
    );
  });

  testWidgets('a saved pinned connection is what the chip offers', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.roomStep,
      initialName: 'Guest host',
      saved: {
        SettingsKeys.transportPin: 'guest',
        SettingsKeys.transportMode: 'guest',
      },
    );
    final s = journey.strings(tester);
    expect(find.text(s.transport_guest), findsOneWidget);
    await _tap(tester, find.byKey(const Key('onboarding-later')));
    expect(journey.modes.pinnedMode, TransferMode.guest);
  });

  testWidgets('replay finishes back in settings with edits preserved', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      replay: true,
      reduced: true,
      initialStep: OnboardingCubit.roomStep,
      initialName: 'Replay rider',
      saved: {SettingsKeys.transportPin: 'bluetooth'},
    );
    final s = journey.strings(tester);
    // A replay has nothing to create or join: it just finishes.
    expect(find.byKey(const Key('onboarding-create-room')), findsNothing);
    expect(_primaryButton(tester).label, s.onboarding_finish);
    await _tap(tester, _primary);
    expect(find.text('Settings restored'), findsOneWidget);
    expect(journey.prefs.getString(SettingsKeys.userName), 'Replay rider');
    expect(journey.prefs.getString(SettingsKeys.transportPin), 'bluetooth');
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(
      journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
      isFalse,
    );
  });

  testWidgets('compact RTL keeps the field usable with the keyboard up', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      initialStep: OnboardingCubit.identityStep,
      size: const Size(360, 640),
      saved: {SettingsKeys.appLocale: 'fa', SettingsKeys.appTheme: 'light'},
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await _settle(tester);
    // The stage steps aside for the field rather than squeezing it.
    expect(find.byType(OnboardingStage), findsNothing);
    final field = find.byKey(const Key('onboarding-callsign-field'));
    await tester.enterText(field, 'کوهنورد');
    expect(journey.cubit(tester).state.canContinue, isTrue);
    expect(Directionality.of(tester.element(field)), TextDirection.rtl);
    await _tap(tester, find.byKey(const Key('onboarding-shuffle')));
    expect(
      RegExp('[۰-۹]{2}').hasMatch(journey.cubit(tester).state.name),
      isTrue,
    );
    await _pickAvatar(tester, 6);
    expect(journey.cubit(tester).state.avatarId, 6);
    expect(_primary.hitTestable(), findsOneWidget);

    tester.view.viewInsets = FakeViewPadding.zero;
    await _settle(tester);
    expect(find.byType(OnboardingStage), findsOneWidget);
    await _tap(tester, _primary);
    expect(journey.cubit(tester).state.step, OnboardingCubit.roomStep);
  });

  testWidgets('system back walks the journey backwards', (tester) async {
    final journey = await _Journey.start(
      tester,
      initialStep: OnboardingCubit.roomStep,
      initialName: 'Walker',
    );
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.identityStep);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(journey.cubit(tester).state.step, OnboardingCubit.helloStep);
  });
}
