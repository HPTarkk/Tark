import 'app_settings.dart';
import 'audio_profile.dart';
import 'noise_suppression_engine.dart';

/// Single point of truth for reading/writing every [AppSettings] field.
///
/// Each cubit that persists one of these fields keeps its own presentation
/// state/responsibility — only the SharedPreferences access itself is
/// unified here, replacing the ad hoc literal-keyed calls that used to be
/// duplicated across SettingsCubit, WalkieTalkieCubit and GuestSessionCubit.
abstract interface class SettingsRepository {
  Future<AppSettings> loadAll();

  Future<String> getMyName();

  /// Language code the UI is running in ('fa' | 'en'). Lets code with no
  /// BuildContext — a cubit composing the fallback display name, say — reach
  /// the same strings the screens use, via lookupAppLocalizations.
  Future<String> getLocaleCode();
  Future<void> setMyName(String value);

  /// Emits after every successful [setMyName], no matter which cubit wrote
  /// it (SettingsCubit, WalkieTalkieCubit, GuestSessionCubit) — lets a page
  /// still alive further down the nav stack (e.g. Landing, under Settings)
  /// show the new name without polling or restarting.
  Stream<String> get myNameChanges;

  Future<double> getVoxMargin();
  Future<void> setVoxMargin(double value);

  Future<double> getNoiseSuppression();
  Future<void> setNoiseSuppression(double value);

  Future<NoiseSuppressionEngine> getNoiseSuppressionEngine();
  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine value);

  Future<double> getMusicGain();
  Future<void> setMusicGain(double value);

  Future<int> getTargetBufferMs();
  Future<void> setTargetBufferMs(int value);

  /// Whether the riding preset is on. Prefer [getAudioProfile] wherever the
  /// answer is going to be combined with the voice knobs — this getter is for
  /// presentation, which needs the raw switch position to draw it.
  Future<bool> getRidingPreset();
  Future<void> setRidingPreset(bool value);

  /// What the audio chain should actually run: the stored voice knobs with
  /// the riding preset applied on top, resolved in one place so no caller can
  /// half-apply it. Every consumer of VOX threshold, cleaner strength/engine,
  /// jitter depth or playback gain goes through this rather than reading the
  /// individual getters above.
  Future<AudioProfile> getAudioProfile();

  Future<bool> getAutoReconnectEnabled();
  Future<void> setAutoReconnectEnabled(bool value);

  Future<bool> getSkipSplash();
  Future<void> setSkipSplash(bool value);

  Future<bool> getUsageTipsShown();
  Future<void> setUsageTipsShown(bool value);

  /// Whether anonymous product analytics may be collected (Settings >
  /// Privacy). Read once at startup — see AdTraceAnalytics.start, which
  /// declines to initialise the SDK at all when this is false.
  Future<bool> getAnalyticsEnabled();
  Future<void> setAnalyticsEnabled(bool value);

  /// Ceiling on the diagnostic log's size on disk, in bytes (Settings >
  /// Advanced > Diagnostics). Always returned inside `LogBudget`'s range,
  /// whatever is stored — the log is not allowed to be uncapped by a bad
  /// preference.
  Future<int> getLogMaxBytes();
  Future<void> setLogMaxBytes(int value);

  /// #31 — whether Shared Music automatically ducks while someone is
  /// talking. Enabled by default for new installs; off leaves shared-music
  /// gain completely unchanged.
  Future<bool> getSmartMusicDuckingEnabled();
  Future<void> setSmartMusicDuckingEnabled(bool value);

  /// Settings > Advanced > HD Voice. See `AudioFormatProfile.hdVoiceEnabled`
  /// for the in-memory flag a caller must also update alongside the write —
  /// this repository only persists the choice.
  Future<bool> getHdVoiceEnabled();
  Future<void> setHdVoiceEnabled(bool value);

  /// Settings > Advanced > HD Shared Music. [getHdVoiceEnabled]'s twin.
  Future<bool> getHdMusicEnabled();
  Future<void> setHdMusicEnabled(bool value);

  // Not part of AppSettings/loadAll() — each of these already has its own
  // narrow, purpose-built owner (BluetoothConnectCubit's "reconnect to last
  // session" shortcut, the background-permission banner's dismissal flag);
  // this repository is just where their SharedPreferences access lives now.
  Future<String?> getLastBluetoothPeerId();
  Future<String?> getLastBluetoothPeerName();
  Future<void> setLastBluetoothPeer({required String id, required String name});

  /// The role ('host' | 'joiner') this device played in its last successful
  /// Bluetooth session, so the next launch can resume the same part
  /// hands-free — a host re-hosts, a joiner re-dials. `null` before any
  /// Bluetooth session has connected.
  Future<String?> getLastBluetoothRole();
  Future<void> setLastBluetoothRole(String role);

  Future<bool> getBgPermBannerDismissed();
  Future<void> setBgPermBannerDismissed(bool value);

  Future<bool> getMusicCastNotifHintDismissed();
  Future<void> setMusicCastNotifHintDismissed(bool value);

  /// Cold-start flow flags (see QuickAccess.resolveStartLocation): "has
  /// completed a Join before" gates quick access, "onboarding completed"
  /// gates the first-run journey. Written by LandingCubit/OnboardingCubit.
  Future<void> setHasLaunchedBefore(bool value);
  Future<void> setOnboardingCompleted(bool value);

  /// Resets every Voice-section field — VOX threshold, noise suppression and
  /// jitter-buffer delay — to [AppSettings.defaults] and persists them,
  /// returning the restored `(vox, noiseSuppression, targetBufferMs)` tuple
  /// so callers can push it into a live session / their own state.
  ///
  /// Turns the riding preset off as part of the reset. Leaving it on would
  /// make "reset to normal" a button that visibly does nothing — every value
  /// it restores is one the preset overrides.
  Future<(double voxMargin, double noiseSuppression, int targetBufferMs)>
  restoreVoiceDefaults();
}
