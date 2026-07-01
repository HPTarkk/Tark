import 'package:go_router/go_router.dart';

import '../../feature/landing/presentation/page/landing_page.dart';
import '../../feature/transfer/presentation/page/bluetooth_connect_page.dart';
import '../../feature/walkie/presentation/page/walkie_talkie_page.dart';

class AppRouter {
  static GoRouter? _router;

  static GoRouter get router {
    _router ??= _buildRoute();
    return _router!;
  }

  static GoRouter _buildRoute() => GoRouter(
        initialLocation: LandingPage.path,
        routes: [
          GoRoute(
            path: LandingPage.path,
            name: LandingPage.name,
            builder: (context, state) => LandingPage.buildPage(),
          ),
          GoRoute(
            path: '/${WalkieTalkiePage.path}',
            name: WalkieTalkiePage.name,
            builder: (context, state) => WalkieTalkiePage.buildPage(),
          ),
          GoRoute(
            path: '/${BluetoothConnectPage.path}',
            name: BluetoothConnectPage.name,
            builder: (context, state) => BluetoothConnectPage.buildPage(),
          ),
        ],
      );
}
