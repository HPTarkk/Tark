import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/config/onboarding_config.dart';
import 'package:tark/core/config/quick_access_config.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/locale/locale_service.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository_impl.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/onboarding/presentation/page/onboarding_page.dart';
import 'package:tark/feature/onboarding/presentation/widget/avatar_step.dart';
import 'package:tark/feature/onboarding/presentation/widget/callsign_step.dart';
import 'package:tark/feature/onboarding/presentation/widget/hud.dart';
import 'package:tark/feature/onboarding/presentation/widget/ready_step.dart';
import 'package:tark/feature/onboarding/presentation/widget/transport_step.dart';
import 'package:tark/feature/onboarding/presentation/widget/tune_step.dart';
import 'package:tark/feature/onboarding/presentation/widget/welcome_step.dart';
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

class _Journey {
  _Journey(this.prefs, this.modes, this.router);

  final SharedPreferences prefs;
  final TransferModeStoreImpl modes;
  final GoRouter router;

  OnboardingCubit cubit(WidgetTester tester) =>
      tester.element(find.byType(OnboardingPage)).read<OnboardingCubit>();

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
      ..registerFactory<OnboardingCubit>(
        () => OnboardingCubit(modes, settings),
      );
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
          builder: (_, _) => const Scaffold(body: Text('Lobby reached')),
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1600));
    return _Journey(prefs, modes, router);
  }
}

Future<void> _advance(WidgetTester tester) async {
  await tester.tap(find.byType(HudActionKey));
  await _transition(tester);
}

Future<void> _transition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 1200));
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'first-run journey validates choices and persists only at launch',
    (tester) async {
      final journey = await _Journey.start(tester);
      expect(find.byType(TuneStep), findsOneWidget);
      final strings = AppLocalizations.of(
        tester.element(find.byType(TuneStep)),
      )!;
      await tester.tap(find.text('فارسی'));
      await _transition(tester);
      expect(LocaleService.currentLocale, const Locale('fa'));
      expect(journey.prefs.getString(SettingsKeys.appLocale), 'fa');
      await tester.tap(find.text('English'));
      await _transition(tester);
      expect(LocaleService.currentLocale, const Locale('en'));

      await tester.tap(find.text(strings.onb_theme_day));
      await _transition(tester);
      expect(journey.cubit(tester).state.themePref, AppThemeMode.light);
      expect(ThemeService.currentMode, AppThemeMode.dark);
      await tester.tap(find.text(strings.onb_theme_night));
      await _transition(tester);
      await _advance(tester);
      expect(find.byType(WelcomeStep), findsOneWidget);
      await _advance(tester);
      expect(find.byType(CallsignStep), findsOneWidget);
      expect(
        tester.widget<HudActionKey>(find.byType(HudActionKey)).enabled,
        isFalse,
      );
      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _transition(tester);
      expect(journey.cubit(tester).state.step, OnboardingCubit.callsignStep);

      await tester.tap(find.byIcon(Icons.casino_rounded));
      await tester.pump();
      expect(journey.cubit(tester).state.name.trim(), isNotEmpty);
      expect(
        tester.widget<HudActionKey>(find.byType(HudActionKey)).enabled,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '  Trail rider  ');
      expect(journey.prefs.getString(SettingsKeys.userName), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _transition(tester);
      expect(find.byType(AvatarStep), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('avatar-5')));
      await tester.pump();
      expect(journey.cubit(tester).state.avatarId, 5);
      expect(journey.prefs.getInt(SettingsKeys.avatarId), isNull);

      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await _transition(tester);
      expect(find.byType(CallsignStep), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '  Trail rider  ',
      );
      await _advance(tester);
      expect(journey.cubit(tester).state.avatarId, 5);
      await _advance(tester);
      expect(find.byType(TransportStep), findsOneWidget);
      expect(journey.cubit(tester).state.mode, isNull);
      for (final choice in [
        (strings.transport_wifi_hotspot, TransferMode.wifi),
        (strings.transport_bluetooth, TransferMode.bluetooth),
        (strings.transport_guest, TransferMode.guest),
      ]) {
        await tester.tap(find.text(choice.$1));
        await tester.pump();
        expect(journey.cubit(tester).state.mode, choice.$2);
        expect(journey.modes.pinnedMode, isNull);
      }
      expect(find.text(strings.transport_automatic), findsNothing);
      await tester.tap(find.text(strings.transport_wifi_hotspot));
      await tester.pump();
      await _advance(tester);
      expect(find.byType(ReadyStep), findsOneWidget);
      expect(journey.cubit(tester).state.mode, TransferMode.wifi);
      expect(
        tester.widget<HudActionKey>(find.byType(HudActionKey)).label,
        strings.join_channel,
      );
      expect(journey.prefs.getBool(OnboardingPrefs.completed), isNull);
      await tester.tap(
        find.text('‹ ${strings.onboarding_explore} ›'.toUpperCase()),
      );
      await _transition(tester);
      expect(find.text('Lobby reached'), findsOneWidget);
      expect(journey.prefs.getString(SettingsKeys.userName), 'Trail rider');
      expect(journey.prefs.getInt(SettingsKeys.avatarId), 5);
      expect(journey.prefs.getString(SettingsKeys.transportPin), 'wifi');
      expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
      expect(
        journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
        isFalse,
      );
    },
  );

  testWidgets('skip discards draft profile and transport edits', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.callsignStep,
      saved: {
        SettingsKeys.userName: 'Saved rider',
        SettingsKeys.avatarId: 3,
        SettingsKeys.transportPin: 'bluetooth',
        SettingsKeys.transportMode: 'bluetooth',
        SettingsKeys.appTheme: 'light',
      },
    );
    expect(find.byType(CallsignStep), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Discard this draft');
    final strings = AppLocalizations.of(
      tester.element(find.byType(CallsignStep)),
    )!;
    await tester.tap(find.text(strings.onboarding_skip));
    await _transition(tester);
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

  testWidgets('pinned transport offers explore without joining a channel', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.launchStep,
      initialName: 'Explorer',
      saved: {
        SettingsKeys.transportPin: 'guest',
        SettingsKeys.transportMode: 'guest',
      },
    );
    final strings = AppLocalizations.of(
      tester.element(find.byType(ReadyStep)),
    )!;
    expect(
      tester.widget<HudActionKey>(find.byType(HudActionKey)).label,
      strings.join_channel,
    );
    await tester.tap(
      find.text('‹ ${strings.onboarding_explore} ›'.toUpperCase()),
    );
    await _transition(tester);
    expect(find.text('Lobby reached'), findsOneWidget);
    expect(journey.modes.pinnedMode, TransferMode.guest);
    expect(journey.prefs.getString(SettingsKeys.userName), 'Explorer');
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(
      journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
      isFalse,
    );
  });

  testWidgets('replay finishes back in settings with edits preserved', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      replay: true,
      reduced: true,
      initialStep: OnboardingCubit.launchStep,
      initialName: 'Replay rider',
      saved: {SettingsKeys.transportPin: 'bluetooth'},
    );
    final strings = AppLocalizations.of(
      tester.element(find.byType(ReadyStep)),
    )!;
    expect(
      tester.widget<HudActionKey>(find.byType(HudActionKey)).label,
      strings.onboarding_finish,
    );
    await _advance(tester);
    expect(find.text('Settings restored'), findsOneWidget);
    expect(journey.prefs.getString(SettingsKeys.userName), 'Replay rider');
    expect(journey.prefs.getBool(OnboardingPrefs.completed), isTrue);
    expect(
      journey.prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false,
      isFalse,
    );
  });

  testWidgets('compact RTL onboarding keeps the field usable with a keyboard', (
    tester,
  ) async {
    final journey = await _Journey.start(
      tester,
      reduced: true,
      initialStep: OnboardingCubit.callsignStep,
      size: const Size(360, 640),
      saved: {SettingsKeys.appLocale: 'fa', SettingsKeys.appTheme: 'light'},
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'کوهنورد');
    expect(journey.cubit(tester).state.canContinue, isTrue);
    expect(
      Directionality.of(tester.element(find.byType(CallsignStep))),
      TextDirection.rtl,
    );
    await tester.tap(find.byIcon(Icons.casino_rounded));
    await tester.pump();
    final generated = journey.cubit(tester).state.name;
    expect(RegExp('[۰-۹]{2}').hasMatch(generated), isTrue);
    await _advance(tester);
    expect(find.byType(AvatarStep), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('avatar-6')));
    await tester.tap(find.byKey(const ValueKey('avatar-6')));
    await tester.pump();
    expect(journey.cubit(tester).state.avatarId, 6);
    expect(tester.takeException(), isNull);
  });
}
