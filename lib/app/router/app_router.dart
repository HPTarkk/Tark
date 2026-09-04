import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/home_widget/home_widget_launch.dart';
import '../../core/router/routes.dart';
import '../../feature/landing/api/landing_api.dart';
import '../../feature/onboarding/api/onboarding_api.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/settings/api/settings_api.dart';
import '../../feature/splash/api/splash_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import 'quick_access.dart';
import 'room_bound_walkie_entry.dart';
import 'room_page_transition.dart';

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
    // Belt-and-braces for widget launch URIs. They are meant to be consumed
    // from the platform intent by HomeWidgetService, never routed — Android
    // disables Flutter's automatic deep linking for exactly that reason (see
    // AndroidManifest). If one reaches the router anyway (a platform that
    // routes it, or a future manifest change re-enabling deep links), turning
    // it into the destination it names is strictly better than the error
    // page. HomeWidgetLaunch.parse requires the tark:// scheme AND the
    // widget host, so a real route like /settings can never match here.
    redirect: (context, state) {
      final launch = HomeWidgetLaunch.parse(state.uri);
      if (launch == null) return null;
      return QuickAccess.locationForLaunch(
        launch,
        GetIt.instance<TransferModeStore>().mode,
      );
    },
    routes: [
      GoRoute(
        path: AppRoutes.splashPath,
        name: AppRoutes.splashName,
        builder: (context, state) => SplashPage.buildPage(
          onFinished: () async {
            final location = QuickAccess.resolveStartLocation(
              GetIt.instance<SharedPreferences>(),
            );
            if (context.mounted) context.go(location);
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.landingPath,
        name: AppRoutes.landingName,
        builder: (context, state) => LandingPage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.onboardingPath,
        name: AppRoutes.onboardingName,
        // `replay` is set when opened from Settings → Startup, so finishing
        // pops back there instead of entering Landing.
        builder: (context, state) => OnboardingPage.buildPage(
          replay: state.uri.queryParameters['replay'] == 'true',
        ),
      ),
      GoRoute(
        path: AppRoutes.roomsPath,
        name: AppRoutes.roomsName,
        pageBuilder: (context, state) => roomPage(
          state,
          RoomManagerEntry.buildPage(
            createOnOpen: state.uri.queryParameters['create'] == 'true',
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.roomQrJoinPath,
        name: AppRoutes.roomQrJoinName,
        pageBuilder: (context, state) =>
            roomPage(state, RoomQrJoinPage.buildPage()),
      ),
      GoRoute(
        path: AppRoutes.roomQrJoinIssuerPath,
        name: AppRoutes.roomQrJoinIssuerName,
        pageBuilder: (context, state) =>
            roomPage(state, RoomQrJoinIssuerPage.buildPage()),
      ),
      GoRoute(
        path: AppRoutes.walkiePath,
        name: AppRoutes.walkieName,
        // `ride` is set only by the screens whose job was establishing a link
        // — the hotspot bridge, Bluetooth pairing, the guest link — on their
        // way back here after the user tapped "Enter channel". Without it the
        // selected Room opens its lobby, which is the deliberate pause every
        // other route into this one wants.
        pageBuilder: (context, state) => roomPage(
          state,
          RoomBoundWalkieEntry.buildPage(
            ride: state.uri.queryParameters['ride'] == 'true',
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.bluetoothConnectPath,
        name: AppRoutes.bluetoothConnectName,
        // `intent` is set when Landing's Create/Join already asked which side
        // this phone is; absent when the page is reached any other way, and
        // then it asks for itself.
        builder: (context, state) => BluetoothConnectPage.buildPage(
          intent: ChannelIntent.fromKey(state.uri.queryParameters['intent']),
        ),
      ),
      GoRoute(
        path: AppRoutes.wifiHotspotPath,
        name: AppRoutes.wifiHotspotName,
        // `extra` carries a QR payload another scanner already read — the
        // Room join page, pointed at the host's Wi-Fi code instead of at an
        // invite. Deliberately not a query parameter: the payload contains
        // the network's passphrase, and a URL is the one place it must never
        // be written.
        builder: (context, state) => WifiHotspotPage.buildPage(
          initialSegment: state.uri.queryParameters['mode'] == 'hotspot'
              ? WifiHotspotSegment.hotspot
              : WifiHotspotSegment.wifi,
          intent: ChannelIntent.fromKey(state.uri.queryParameters['intent']),
          handedCode: state.extra is String ? state.extra! as String : null,
        ),
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
      GoRoute(
        path: AppRoutes.permissionsPath,
        name: AppRoutes.permissionsName,
        builder: (context, state) => PermissionsPage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.advancedSettingsPath,
        name: AppRoutes.advancedSettingsName,
        // Same live-session threading as the settings route above — the
        // main Settings page forwards its own `extra` when pushing here.
        builder: (context, state) =>
            AdvancedSettingsPage.buildPage(liveSession: state.extra),
      ),
    ],
  );
}
