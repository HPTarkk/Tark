import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/onboarding_config.dart';
import '../../core/config/quick_access_config.dart';
import '../../core/home_widget/home_widget_launch.dart';
import '../../core/router/routes.dart';
import '../../core/settings/connection_history.dart';
import '../../feature/transfer/api/transfer_api.dart';

/// Decides where the app lands on cold start.
///
/// A true first run (never onboarded, never completed a Join) goes through
/// the onboarding journey. Existing installs that predate onboarding are
/// grandfathered past it via [QuickAccessPrefs.hasLaunchedBefore]. Everyone
/// else lands on Landing — see AppRouter.startLocation, set from this in
/// main.dart before the first read of AppRouter.router.
///
/// Cold start used to skip Landing and drop returning users straight into
/// their last-used [TransferMode]. The home-screen widget replaced that: it
/// offers the same one-tap route into a channel, but only when the user
/// actually asks for it, instead of taking the decision away from every
/// launch. [locationForMode] is what the widget now uses.
///
/// The one exception is a Bluetooth call: when the last call ran over
/// Bluetooth, cold start opens the resume screen, which reconnects to that
/// phone, shows the result, then returns home (see [shouldResumeBluetooth]).
abstract final class QuickAccess {
  static String resolveStartLocation(
    SharedPreferences prefs, {
    bool? isAndroid,
  }) {
    final hasLaunched =
        prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false;
    final onboarded = prefs.getBool(OnboardingPrefs.completed) ?? false;
    if (!onboarded && !hasLaunched) return AppRoutes.onboardingPath;
    if (shouldResumeBluetooth(prefs, isAndroid: isAndroid)) {
      return AppRoutes.bluetoothResumePath;
    }
    return AppRoutes.landingPath;
  }

  /// Whether cold start should try to reconnect the last Bluetooth call.
  ///
  /// Every condition is one the resume screen could not recover from on its
  /// own, so it is cheaper to not open it at all:
  /// - Android only — the hands-free resume is built on Classic RFCOMM, which
  ///   is what makes a cold dial by address possible.
  /// - The Auto-reconnect setting is on.
  /// - Bluetooth is still selected and the last verified connection used
  ///   Classic Bluetooth. Changing settings alone is not connection history.
  /// - The remembered role is usable; a joiner also needs the phone it dialed.
  ///
  /// Permissions and the radio are checked by the screen itself, since they
  /// need platform calls; when either is missing it steps aside to Landing.
  static bool shouldResumeBluetooth(
    SharedPreferences prefs, {
    bool? isAndroid,
  }) => ConnectionHistory(
    prefs,
  ).shouldResumeClassicBluetooth(isAndroid: isAndroid ?? Platform.isAndroid);

  /// The page that puts the user on air fastest for [mode] — used by the
  /// home-screen widget's GO LIVE button, an explicit request to skip
  /// Landing.
  ///
  /// Arriving here is all it takes to go live: [WalkieTalkieState] starts
  /// un-muted, so VOX opens the mic as soon as the channel is up.
  static String locationForMode(TransferMode mode) => switch (mode) {
    // Plain WiFi keeps the zero-friction fast path straight to the channel
    // — nothing to set up, unlike hotspot mode below.
    TransferMode.wifi => AppRoutes.walkiePath,
    TransferMode.bluetooth => AppRoutes.bluetoothConnectPath,
    TransferMode.hotspot => '${AppRoutes.wifiHotspotPath}?mode=hotspot',
    TransferMode.guest => AppRoutes.guestLinkPath,
  };

  /// Where a home-screen widget tap should land.
  ///
  /// [HomeWidgetIntent.open] deliberately stops at Landing rather than the
  /// channel: it backs the mode badge, which exists so there is always a way
  /// into the app from the widget that cannot start transmitting.
  static String locationForLaunch(
    HomeWidgetLaunch launch,
    TransferMode lastMode,
  ) => switch (launch.intent) {
    HomeWidgetIntent.goLive => locationForMode(lastMode),
    HomeWidgetIntent.open => AppRoutes.landingPath,
    HomeWidgetIntent.setup => AppRoutes.onboardingPath,
    HomeWidgetIntent.settings => AppRoutes.settingsPath,
  };
}
