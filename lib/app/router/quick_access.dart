import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/quick_access_config.dart';
import '../../core/router/routes.dart';
import '../../feature/transfer/api/transfer_api.dart';

/// Decides where the app lands on cold start.
///
/// First-ever launch (or quick access turned off in Settings) always shows
/// Landing. Otherwise, returning users skip straight to the page for their
/// last-used [TransferMode] — see AppRouter.startLocation, set from this in
/// main.dart before the first read of AppRouter.router.
abstract final class QuickAccess {
  static Future<String> resolveStartLocation(TransferMode lastMode) async {
    final prefs = await SharedPreferences.getInstance();
    final hasLaunched =
        prefs.getBool(QuickAccessPrefs.hasLaunchedBefore) ?? false;
    final enabled = prefs.getBool(QuickAccessPrefs.enabled) ?? true;
    if (!hasLaunched || !enabled) return AppRoutes.landingPath;
    return switch (lastMode) {
      TransferMode.wifi => AppRoutes.walkiePath,
      TransferMode.bluetooth => AppRoutes.bluetoothConnectPath,
      TransferMode.hotspot => AppRoutes.hotspotBridgePath,
      TransferMode.guest => AppRoutes.guestLinkPath,
    };
  }
}
