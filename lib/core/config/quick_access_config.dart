/// SharedPreferences key for the cold-start flow (see
/// lib/app/router/quick_access.dart) — written by [LandingCubit] the first
/// time a user completes the Join flow, and read by QuickAccess to decide
/// whether a cold start routes through onboarding first.
///
/// There used to be a second key here, `quick_access_enabled`, backing a
/// Settings toggle that let cold start skip Landing for the last-used
/// transport. The home-screen widget replaced that behaviour — same one-tap
/// route into a channel, but on request rather than on every launch — so the
/// key is gone. It is simply left behind in existing installs; nothing reads
/// it, and reusing the name later would inherit stale values.
abstract final class QuickAccessPrefs {
  static const hasLaunchedBefore = 'has_launched_before';
}
