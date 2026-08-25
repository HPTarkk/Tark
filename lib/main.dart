import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/di/di_config.dart';
import 'app/my_app.dart';
import 'app/router/app_router.dart';
import 'app/router/quick_access.dart';
import 'core/analytics/analytics.dart';
import 'core/audio/audio_format_profile.dart';
import 'core/config/onboarding_config.dart';
import 'core/diagnostics/diagnostic_log.dart';
import 'core/diagnostics/lifecycle_log.dart';
import 'core/diagnostics/log_budget.dart';
import 'core/entitlement/entitlement_store.dart';
import 'core/home_widget/home_widget_service.dart';
import 'core/home_widget/home_widget_snapshot.dart';
import 'core/locale/locale_service.dart';
import 'core/router/routes.dart';
import 'core/settings/settings_keys.dart';
import 'core/settings/settings_repository.dart';
import 'core/sfx/sfx_service.dart';
import 'core/theme/theme_service.dart';
import 'core/utils/logger.dart';
import 'feature/transfer/api/transfer_api.dart';
import 'feature/transfer/data/android_network_rebind_coordinator.dart';
import 'feature/transfer/domain/repository/wifi_transfer_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // First, so everything below is on the record. The file this opens is what
  // turns "it stopped working on the ride home" into something diagnosable —
  // see DiagnosticLog. Not awaited past its own directory lookup: nothing here
  // may sit in front of the first frame, and lines emitted before the
  // directory resolves are held in memory and flushed once it does.
  unawaited(DiagnosticLog.initialize());
  // Screen-off/on is the single most useful thing to correlate socket and
  // audio events against — most of what goes wrong mid-session goes wrong
  // because the phone locked.
  LifecycleLog.install();
  // Async errors that no call site can own end up here. The one that actually
  // fires is flutter_blue_classic's startScan/stopScan: both are declared
  // `void` and drop the platform-channel Future inside the plugin, so a
  // refused scan permission (Android 9 still gates discovery on
  // ACCESS_FINE_LOCATION, and the request comes back cancelled whenever
  // another prompt is already up) escapes as an unhandled PlatformException
  // no `try` of ours can reach. Log it and keep going — a scan that never
  // started just finds nothing, which the joiner screen already copes with.
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    // diagnostic, not log: an error nobody caught is rare, high-value, and by
    // definition only observed where it happened — which is the one category
    // that has to survive into a release build's log file.
    Logger.diagnostic('Unhandled async error: $error\n$stack');
    return true;
  };
  // The one SharedPreferences resolution for the whole process: handed to
  // the pre-DI services here, and registered in the DI graph (see
  // RegisterThirdParty.prefs — getInstance() returns this same cached
  // instance) for everything constructed after configureDependencies().
  final prefs = await SharedPreferences.getInstance();
  // The log has been buffering since the top of main() under the default
  // ceiling; hand it the user's own as soon as prefs can be read, so a phone
  // whose owner asked for 20 KB never briefly holds eight.
  unawaited(
    DiagnosticLog.setMaxBytes(
      prefs.getInt(SettingsKeys.logMaxBytes) ?? LogBudget.defaultBytes,
    ),
  );
  // Same reasoning: every TransferRepository is a DI singleton that reads
  // AudioFormatProfile.hdVoiceEnabled/hdMusicEnabled live (see their doc)
  // rather than caching a value at construction, but the in-memory default
  // is always on — a user who turned either off needs it applied here,
  // before the first presence packet of the process ever goes out, or the
  // very first channel would negotiate as if they hadn't.
  AudioFormatProfile.hdVoiceEnabled =
      prefs.getBool(SettingsKeys.hdVoiceEnabled) ?? true;
  AudioFormatProfile.hdMusicEnabled =
      prefs.getBool(SettingsKeys.hdMusicEnabled) ?? true;
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
  // Strictly before the mode store below: that one asks LicenseGate whether
  // the persisted transport is still paid for, and on a genuinely first
  // launch this call is what starts the trial clock.
  await GetIt.instance<EntitlementStore>().initialize();
  // Must complete before the first page builds: the DI factory that picks
  // the active TransferRepository reads the persisted mode synchronously.
  final modeStore = GetIt.instance<TransferModeStore>();
  await modeStore.initialize();

  // Process/network binding is an Android transport concern, not room state.
  // Keep it aligned with the selected local Wi-Fi generation for the lifetime
  // of the process; rebindSockets rebuilds both UDP sockets underneath the same
  // listening stream and therefore never leaves/recreates the logical room.
  final networkRebindCoordinator = AndroidNetworkRebindCoordinator(
    GetIt.instance<WifiTransferRepository>().rebindSockets,
    modeStore,
  );
  await networkRebindCoordinator.start();

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
