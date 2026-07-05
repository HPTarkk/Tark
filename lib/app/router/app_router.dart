import 'package:go_router/go_router.dart';

import '../../core/router/routes.dart';
import '../../feature/landing/api/landing_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import '../../feature/walkie/api/walkie_api.dart';

/// App composition root for navigation: the only place where pages from
/// different features are wired together. Features themselves navigate by
/// [AppRoutes] names and never import each other's pages.
class AppRouter {
  static GoRouter? _router;

  static GoRouter get router {
    _router ??= _buildRoute();
    return _router!;
  }

  static GoRouter _buildRoute() => GoRouter(
        initialLocation: AppRoutes.landingPath,
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
        ],
      );
}
