/// SharedPreferences keys for the quick-access cold-start flow (see
/// lib/app/router/quick_access.dart) — shared between [LandingCubit] (writes
/// [hasLaunchedBefore] the first time a user completes the Join flow),
/// SettingsCubit (writes [enabled] from the Settings page toggle), and
/// QuickAccess itself (reads both to decide the router's initial location).
abstract final class QuickAccessPrefs {
  static const hasLaunchedBefore = 'has_launched_before';
  static const enabled = 'quick_access_enabled';
}
