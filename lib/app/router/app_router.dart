import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/account/email_link.dart';
import '../../core/beta/beta_intro.dart';
import '../../core/diagnostics/screen_log.dart';
import '../../core/motion/continuity_route.dart';
import '../../core/entitlement/feature_access_guard.dart';
import '../../core/entitlement/premium_feature.dart';
import '../../core/motion/solid_sheet_route.dart';
import '../../core/router/route_exit.dart';
import '../../core/home_widget/home_widget_launch.dart';
import '../../core/router/routes.dart';
import '../../feature/account/api/account_api.dart';
import '../../feature/landing/api/landing_api.dart';
import '../../feature/onboarding/api/onboarding_api.dart';
import '../../feature/room/api/room_api.dart';
import '../../feature/settings/api/settings_api.dart';
import '../../feature/splash/api/splash_api.dart';
import '../../feature/transfer/api/transfer_api.dart';
import 'quick_access.dart';
import 'room_bound_walkie_entry.dart';

/// App composition root for navigation: the only place where pages from
/// different features are wired together. Features themselves navigate by
/// [AppRoutes] names and never import each other's pages.
class AppRouter {
  static Widget _ipAccess(BuildContext context, WidgetBuilder builder) =>
      FeatureAccessGuard(
        feature: PremiumFeature.wifiTransport,
        builder: builder,
        onDenied: () => exitRouteTo(context, AppRoutes.roomsPath),
      );

  /// The page for a route that can be arrived at *continuously*: a
  /// [ContinuityPage] when the navigation carried a [ContinuityHandoff] as
  /// `extra` (onboarding handing over to Landing, room creation, or the join
  /// scanner), otherwise exactly the page a plain `builder:` route gets, so
  /// every other way into the route is untouched.
  static Page<void> pageFor(GoRouterState state, Widget child) {
    final name = state.name ?? state.path;
    final arguments = <String, String>{
      ...state.pathParameters,
      ...state.uri.queryParameters,
    };
    if (state.extra is ContinuityHandoff) {
      return ContinuityPage<void>(
        key: state.pageKey,
        name: name,
        arguments: arguments,
        restorationId: state.pageKey.value,
        child: child,
      );
    }
    return MaterialPage<void>(
      key: state.pageKey,
      name: name,
      arguments: arguments,
      restorationId: state.pageKey.value,
      child: child,
    );
  }

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
    // Every page, sheet and dialog the user opens goes into the .tarklog.
    observers: [ScreenLog()],
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
        GetIt.instance<TransferModeStore>().connectionChoice,
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
        // Onboarding's "later" and skip hand the screen over with a
        // ContinuityHandoff — see pageFor.
        pageBuilder: (context, state) =>
            pageFor(state, LandingPage.buildPage()),
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
        // Creation arrives and leaves as a solid sheet over the screen that
        // opened it, which recedes behind it — never a crossfade of the two.
        // Onboarding's hand-off keeps its own continuity transition, and the
        // saved-room list keeps the app-wide one. `name` suggests the new
        // Room's name (onboarding derives it from the callsign it just
        // collected); only read together with `create`.
        pageBuilder: (context, state) {
          final create = state.uri.queryParameters['create'] == 'true';
          final continuous = state.extra is ContinuityHandoff;
          final child = RoomManagerEntry.buildPage(
            createOnOpen: create,
            initialName: state.uri.queryParameters['name'],
            continuous: continuous,
          );
          if (!create || continuous) return pageFor(state, child);
          return SolidSheetPage<void>(
            key: state.pageKey,
            name: state.name ?? state.path,
            arguments: {
              ...state.pathParameters,
              ...state.uri.queryParameters,
            },
            restorationId: state.pageKey.value,
            child: child,
          );
        },
      ),
      GoRoute(
        path: AppRoutes.roomQrJoinPath,
        name: AppRoutes.roomQrJoinName,
        pageBuilder: (context, state) => pageFor(
          state,
          _ipAccess(context, (_) => RoomQrJoinPage.buildPage()),
        ),
      ),
      GoRoute(
        path: AppRoutes.roomQrJoinIssuerPath,
        name: AppRoutes.roomQrJoinIssuerName,
        builder: (context, state) =>
            _ipAccess(context, (_) => RoomQrJoinIssuerPage.buildPage()),
      ),
      GoRoute(
        path: AppRoutes.walkiePath,
        name: AppRoutes.walkieName,
        // `ride` is set only by the screens whose job was establishing a link
        // — the hotspot bridge, Bluetooth pairing, the guest link — on their
        // way back here after the user tapped "Enter channel". Without it the
        // selected Room opens its lobby, which is the deliberate pause every
        // other route into this one wants.
        //
        // `start` is set by the invite scanner once a join is accepted: the
        // Room connects straight away over the hand-off the scan opened.
        //
        // `rejoin` is set by Landing's "Get back to …?" question, after the
        // app stopped in the middle of a Room's call.
        builder: (context, state) => RoomBoundWalkieEntry.buildPage(
          ride: state.uri.queryParameters['ride'] == 'true',
          start: state.uri.queryParameters['start'] == 'true',
          rejoin: state.uri.queryParameters['rejoin'] == 'true',
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
        path: AppRoutes.bluetoothResumePath,
        name: AppRoutes.bluetoothResumeName,
        // Cold start only, when the last call ran over Bluetooth — see
        // QuickAccess.shouldResumeBluetooth.
        builder: (context, state) => BluetoothResumePage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.wifiHotspotPath,
        name: AppRoutes.wifiHotspotName,
        // `extra` carries a QR payload another scanner already read — the
        // Room join page, pointed at the host's Wi-Fi code instead of at an
        // invite. Deliberately not a query parameter: the payload contains
        // the network's passphrase, and a URL is the one place it must never
        // be written.
        builder: (context, state) => _ipAccess(
          context,
          (_) => WifiHotspotPage.buildPage(
            initialSegment: state.uri.queryParameters['mode'] == 'hotspot'
                ? WifiHotspotSegment.hotspot
                : WifiHotspotSegment.wifi,
            intent: ChannelIntent.fromKey(state.uri.queryParameters['intent']),
            handedCode: state.extra is String ? state.extra! as String : null,
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.guestLinkPath,
        name: AppRoutes.guestLinkName,
        // Free, and shipped as a beta: no subscription gate, but the first
        // visit on an install is met by the friendly beta intro.
        builder: (context, state) => BetaIntroGate(
          feature: TransferMode.guest.betaFeature!,
          child: GuestLinkPage.buildPage(),
        ),
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
        path: AppRoutes.profilePath,
        name: AppRoutes.profileName,
        // Same live-session threading as Advanced below: Settings forwards
        // its own `extra`, so a mid-channel change reaches the channel.
        builder: (context, state) =>
            ProfilePage.buildPage(liveSession: state.extra),
      ),
      GoRoute(
        path: AppRoutes.permissionsPath,
        name: AppRoutes.permissionsName,
        builder: (context, state) => PermissionsPage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.signInPath,
        name: AppRoutes.signInName,
        builder: (context, state) => SignInPage.buildPage(),
      ),
      GoRoute(
        path: AppRoutes.accountLinkPath,
        name: AppRoutes.accountLinkName,
        // `extra` is the EmailLink that opened the app. Never a query
        // parameter: the link token finishes a sign-up or a password reset,
        // and a URL is the one place it must not be written down.
        builder: (context, state) => switch (state.extra) {
          final EmailLink link => CodeEntryPage.buildForLink(link),
          _ => SignInPage.buildPage(),
        },
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
