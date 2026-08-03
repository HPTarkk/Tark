import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/di/di_config.dart';
import 'app/my_app.dart';
import 'app/router/app_router.dart';
import 'app/router/quick_access.dart';
import 'core/analytics/analytics.dart';
import 'core/config/onboarding_config.dart';
import 'core/home_widget/home_widget_service.dart';
import 'core/home_widget/home_widget_snapshot.dart';
import 'core/locale/locale_service.dart';
import 'core/router/routes.dart';
import 'core/settings/settings_repository.dart';
import 'core/sfx/sfx_service.dart';
import 'core/utils/logger.dart';
import 'core/theme/theme_service.dart';
import 'feature/transfer/api/transfer_api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Async errors that no call site can own end up here. The one that actually
  // fires is flutter_blue_classic's startScan/stopScan: both are declared
  // `void` and drop the platform-channel Future inside the plugin, so a
  // refused scan permission (Android 9 still gates discovery on
  // ACCESS_FINE_LOCATION, and the request comes back cancelled whenever
  // another prompt is already up) escapes as an unhandled PlatformException
  // no `try` of ours can reach. Log it and keep going — a scan that never
  // started just finds nothing, which the joiner screen already copes with.
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    Logger.log('Unhandled async error: $error\n$stack');
    return true;
  };
  // The one SharedPreferences resolution for the whole process: handed to
  // the pre-DI services here, and registered in the DI graph (see
  // RegisterThirdParty.prefs — getInstance() returns this same cached
  // instance) for everything constructed after configureDependencies().
  final prefs = await SharedPreferences.getInstance();
  LocaleService.initialize(prefs);
  ThemeService.initialize(prefs);
  await Sfx.initialize(prefs);
  // Loads libopus once for the process; on failure the codec transparently
  // falls back to PCM16, so this must never block or crash startup.
  await OpusAudioCodec.ensureInitialized();
  await configureDependencies();
  // Deliberately not awaited: analytics is never allowed to sit on the
  // critical path to the first frame. It reads the opt-out flag itself and
  // does nothing at all if the user turned it off.
  unawaited(GetIt.instance<Analytics>().start());
  // Must complete before the first page builds: the DI factory that picks
  // the active TransferRepository reads the persisted mode synchronously.
  final modeStore = GetIt.instance<TransferModeStore>();
  await modeStore.initialize();
  // Same reasoning: AppRouter.router is memoized on first read (inside
  // MyApp's build below), so this must also complete before runApp().
  final skipSplash = await GetIt.instance<SettingsRepository>().getSkipSplash();

  final homeWidget = GetIt.instance<HomeWidgetService>();
  await homeWidget.initialize();
  // A widget tap outranks both the splash screen and the quick-access
  // setting — the user asked for a specific destination, so honour it
  // instead of replaying the normal cold-start decision.
  final launch = await homeWidget.takeInitialLaunch();
  AppRouter.startLocation = switch (launch) {
    final l? => QuickAccess.locationForLaunch(l, modeStore.mode),
    _ when skipSplash => QuickAccess.resolveStartLocation(prefs),
    _ => AppRoutes.splashPath,
  };

  // Repaint the widget with resting state before the first frame: one added
  // while the app was closed renders whatever the last session left behind,
  // which after a crash or an OS kill can be a stale "LIVE".
  unawaited(
    homeWidget.publish(
      (prefs.getBool(OnboardingPrefs.completed) ?? false)
          ? HomeWidgetSnapshot.idle(
              modeKey: modeStore.mode.key,
              callsign: await GetIt.instance<SettingsRepository>().getMyName(),
            )
          : const HomeWidgetSnapshot.setup(),
    ),
  );

  runApp(const MyApp());
}
