import 'package:go_router/go_router.dart';

import '../../core/router/routes.dart';
import '../../feature/landing/api/landing_api.dart';
import '../../feature/settings/api/settings_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';

/// App composition root for navigation: the only place where pages from
/// different features are wired together. Features themselves navigate by
/// [AppRoutes] names and never import each other's pages.
class AppRouter {
  static GoRouter? _router;

  /// Where the app lands on cold start — [AppRoutes.landingPath] by default,
  /// overridden by `main.dart` (via `QuickAccess.resolveStartLocation`)
  /// before the first read of [router]. Setting this plain static field
  /// synchronously before `runApp()` is race-free (single-threaded Dart,
  /// `router` is first read only inside `MyApp`'s build).
  static String startLocation = AppRoutes.landingPath;

  static GoRouter get router {
    _router ??= _buildRoute();
    return _router!;
  }

  static GoRouter _buildRoute() => GoRouter(
        initialLocation: startLocation,
        routes: [
          GoRoute(
            path: AppRoutes.landingPath,
            name: AppRoutes.landingName,
            builder: (context, state) => LandingPage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.walkiePath,
            name: AppRoutes.walkieName,
            builder: (context, state) => WalkieTalkiePage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.bluetoothConnectPath,
            name: AppRoutes.bluetoothConnectName,
            builder: (context, state) => BluetoothConnectPage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.hotspotBridgePath,
            name: AppRoutes.hotspotBridgeName,
            builder: (context, state) => HotspotBridgePage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.guestLinkPath,
            name: AppRoutes.guestLinkName,
            builder: (context, state) => GuestLinkPage.buildPage(),
          ),
          GoRoute(
            path: AppRoutes.settingsPath,
            name: AppRoutes.settingsName,
            // `extra` carries an already-running WalkieTalkieCubit when
            // opened from an active channel (see WalkieHeader's gear icon),
            // so Settings can edit that live session in place — null when
            // opened from Landing, before any session exists.
            builder: (context, state) =>
                SettingsPage.buildPage(liveSession: state.extra),
          ),
        ],
      );
}
