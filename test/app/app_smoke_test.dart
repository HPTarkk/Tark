import 'dart:async';

import 'package:audio_io/audio_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/di/di_config.dart';
import 'package:tark/app/my_app.dart';
import 'package:tark/app/router/app_router.dart';
import 'package:tark/core/config/onboarding_config.dart';
import 'package:tark/core/home_widget/home_widget_launch.dart';
import 'package:tark/core/home_widget/home_widget_service.dart';
import 'package:tark/core/home_widget/home_widget_snapshot.dart';
import 'package:tark/core/home_widget/widget_control_channel.dart';
import 'package:tark/core/locale/locale_service.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/feature/settings/presentation/page/profile_page.dart';
import 'package:tark/feature/settings/presentation/page/advanced_settings_page.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

class _AudioDevice extends AudioIo {
  int disposals = 0;

  @override
  void dispose() => disposals++;
}

class _HomeWidgets implements HomeWidgetService {
  final events = StreamController<HomeWidgetLaunch>.broadcast();
  int refreshes = 0;

  @override
  Stream<HomeWidgetLaunch> get launches => events.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> publish(HomeWidgetSnapshot snapshot) async {}
  @override
  Future<void> refresh() async => refreshes++;
  @override
  Future<bool> canPin() async => false;
  @override
  Future<void> requestPin() async {}
  @override
  Future<HomeWidgetLaunch?> takeInitialLaunch() async => null;
  @override
  void dispose() => events.close();
}

class _WidgetControls implements WidgetControlChannel {
  final events = StreamController<WidgetControlAction>.broadcast();
  @override
  Stream<WidgetControlAction> get actions => events.stream;
  @override
  void dispose() => events.close();
}

// Exercises the real app, generated DI graph, router and persisted settings.
// Only OS audio and launcher boundaries are replaced with deterministic ports.
void main() {
  testWidgets('cold start, settings and widget controls preserve app state', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PackageInfo.setMockInitialValues(
      appName: 'Tark',
      packageName: 'com.b1101.tark',
      version: '1.1.0',
      buildNumber: '32',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({
      OnboardingPrefs.completed: true,
      SettingsKeys.userName: 'Audio tester',
      SettingsKeys.avatarId: 3,
      SettingsKeys.appLocale: 'en',
    });
    final prefs = await SharedPreferences.getInstance();
    LocaleService.initialize(prefs);
    ThemeService.initialize(prefs);
    await configureDependencies();
    final audio = _AudioDevice();
    final widgets = _HomeWidgets();
    final controls = _WidgetControls();
    await GetIt.instance.unregister<AudioIo>();
    await GetIt.instance.unregister<HomeWidgetService>();
    await GetIt.instance.unregister<WidgetControlChannel>();
    GetIt.instance
      ..registerSingleton<AudioIo>(audio)
      ..registerSingleton<HomeWidgetService>(widgets)
      ..registerSingleton<WidgetControlChannel>(controls);
    await GetIt.instance<TransferModeStore>().initialize();
    AppRouter.startLocation = AppRoutes.splashPath;
    final router = AppRouter.router;
    addTearDown(() async {
      router.dispose();
      widgets.dispose();
      controls.dispose();
      await GetIt.instance.reset();
    });

    await tester.pumpWidget(const MyApp());
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoutes.splashPath,
    );
    await tester.pump(const Duration(milliseconds: 3501));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoutes.landingPath,
    );
    expect(find.byKey(const Key('landing-create-room')), findsOneWidget);
    expect(find.text('Audio tester'), findsOneWidget);
    expect(tester.takeException(), isNull);

    router.pushNamed(AppRoutes.settingsName);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(find.text('PROFILE'), findsOneWidget);

    // Settings remains the control plane for the native audio pipeline.
    // Follow the actual route and verify that user edits survive reopening.
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('Advanced settings'));
    await tester.tap(find.text('Advanced settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AdvancedSettingsPage), findsOneWidget);
    await tester.tap(find.text('BLUETOOTH'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString(SettingsKeys.transportPin), 'bluetooth');
    await tester.tap(find.text('AUTOMATIC'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(GetIt.instance<TransferModeStore>().pinnedMode, isNull);

    final vox = find.byType(Slider).first;
    await tester.ensureVisible(vox);
    await tester.drag(vox, const Offset(80, 0));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final savedMargin = prefs.getDouble(SettingsKeys.voxMargin);
    expect(savedMargin, isNotNull);
    expect(savedMargin, closeTo(tester.widget<Slider>(vox).value, 1e-9));

    final hdVoice = find.byType(Switch).first;
    await tester.ensureVisible(hdVoice);
    await tester.tap(hdVoice);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getBool(SettingsKeys.hdVoiceEnabled), isFalse);
    await tester.ensureVisible(find.text('No cleaner'));
    await tester.tap(find.text('No cleaner'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString(SettingsKeys.noiseSuppressionEngine), 'off');
    expect(tester.widget<Slider>(find.byType(Slider).at(1)).onChanged, isNull);

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.text('Advanced settings'));
    await tester.tap(find.text('Advanced settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Slider>(find.byType(Slider).first).value, savedMargin);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(tester.widget<Slider>(find.byType(Slider).at(1)).onChanged, isNull);
    expect(tester.takeException(), isNull);
    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.ensureVisible(find.byKey(const ValueKey('settings-profile')));
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await LocaleService.setLocale(const Locale('fa'));
    await ThemeService.setMode(AppThemeMode.light);
    await tester.pump();
    expect(find.byType(ProfilePage), findsOneWidget);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
      const Locale('fa'),
    );
    expect(widgets.refreshes, 2);
    expect(prefs.getString(SettingsKeys.appLocale), 'fa');
    expect(prefs.getString(SettingsKeys.appTheme), 'light');

    controls.events.add(WidgetControlAction.endSession);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoutes.landingPath,
    );
    expect(find.byKey(const Key('landing-create-room')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(audio.disposals, 1);
    expect(widgets.events.hasListener, isFalse);
    expect(controls.events.hasListener, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });
}
