import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/onboarding_config.dart';
import '../../core/config/quick_access_config.dart';
import '../../core/router/routes.dart';
import '../../feature/transfer/api/transfer_api.dart';

/// Decides where the app lands on cold start.
///
/// A true first run (never onboarded, never completed a Join) goes through
/// the onboarding journey. Existing installs that predate onboarding are
/// grandfathered past it via [QuickAccessPrefs.hasLaunchedBefore]. After
/// that: first launch (or quick access turned off in Settings) shows
/// Landing, and returning users skip straight to the page for their
/// last-used [TransferMode] — see AppRouter.startLocation, set from this in
/// main.dart before the first read of AppRouter.router.
abstract final class QuickAccess {
  static String resolveStartLocation(
    TransferMode lastMode,
    SharedPreferences prefs,
  ) {
    final hasLaunched =
        prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false;
    final enabled = prefs.getBool(QuickAccessPrefs.enabled) ?? true;
    final onboarded = prefs.getBool(OnboardingPrefs.completed) ?? false;
    if (!onboarded && !hasLaunched) return AppRoutes.onboardingPath;
    if (!hasLaunched || !enabled) return AppRoutes.landingPath;
    return switch (lastMode) {
      // Plain WiFi keeps the zero-friction fast path straight to the channel
      // — nothing to set up, unlike hotspot mode below.
      TransferMode.wifi => AppRoutes.walkiePath,
      TransferMode.bluetooth => AppRoutes.bluetoothConnectPath,
      TransferMode.hotspot => '${AppRoutes.wifiHotspotPath}?mode=hotspot',
      TransferMode.guest => AppRoutes.guestLinkPath,
    };
  }
}
