/// Route table constants shared by all features.
///
/// Features navigate with `context.pushNamed(AppRoutes.<x>Name)` and never
/// import another feature's page widget — the actual page-to-route wiring
/// lives in the app composition root (lib/app/router/app_router.dart).
abstract final class AppRoutes {
  static const splashName = 'SplashPage';
  static const splashPath = '/splash';

  static const landingName = 'LandingPage';
  static const landingPath = '/';

  static const onboardingName = 'OnboardingPage';
  static const onboardingPath = '/onboarding';

  static const walkieName = 'WalkieTalkiePage';
  static const walkiePath = '/walkie';

  static const bluetoothConnectName = 'BluetoothConnectPage';
  static const bluetoothConnectPath = '/bluetooth-connect';

  static const wifiHotspotName = 'WifiHotspotPage';
  static const wifiHotspotPath = '/wifi-hotspot';

  static const guestLinkName = 'GuestLinkPage';
  static const guestLinkPath = '/guest-link';

  static const settingsName = 'SettingsPage';
  static const settingsPath = '/settings';

  static const permissionsName = 'PermissionsPage';
  static const permissionsPath = '/settings/permissions';
}
