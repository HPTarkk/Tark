/// SharedPreferences keys for the first-run onboarding journey (see
/// lib/feature/onboarding) — written by OnboardingCubit when the user
/// finishes or skips the flow, read by QuickAccess to decide whether a cold
/// start should route through the onboarding scene first.
abstract final class OnboardingPrefs {
  static const completed = 'onboarding_completed';
}
