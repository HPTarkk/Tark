import 'app_settings.dart';

/// Single point of truth for reading/writing every [AppSettings] field.
///
/// Each cubit that persists one of these fields keeps its own presentation
/// state/responsibility — only the SharedPreferences access itself is
/// unified here, replacing the ad hoc literal-keyed calls that used to be
/// duplicated across SettingsCubit, WalkieTalkieCubit and GuestSessionCubit.
abstract interface class SettingsRepository {
  Future<AppSettings> loadAll();

  Future<String> getMyName();
  Future<void> setMyName(String value);

  /// Emits after every successful [setMyName], no matter which cubit wrote
  /// it (SettingsCubit, WalkieTalkieCubit, GuestSessionCubit) — lets a page
  /// still alive further down the nav stack (e.g. Landing, under Settings)
  /// show the new name without polling or restarting.
  Stream<String> get myNameChanges;

  Future<double> getVoxThreshold();
  Future<void> setVoxThreshold(double value);

  Future<double> getNoiseSuppression();
  Future<void> setNoiseSuppression(double value);

  Future<double> getMusicGain();
  Future<void> setMusicGain(double value);

  Future<int> getTargetBufferMs();
  Future<void> setTargetBufferMs(int value);

  Future<bool> getAutoReconnectEnabled();
  Future<void> setAutoReconnectEnabled(bool value);

  Future<bool> getSkipSplash();
  Future<void> setSkipSplash(bool value);

  Future<bool> getQuickAccessEnabled();
  Future<void> setQuickAccessEnabled(bool value);

  Future<bool> getUsageTipsShown();
  Future<void> setUsageTipsShown(bool value);

  // Not part of AppSettings/loadAll() — each of these already has its own
  // narrow, purpose-built owner (BluetoothConnectCubit's "reconnect to last
  // session" shortcut, the background-permission banner's dismissal flag);
  // this repository is just where their SharedPreferences access lives now.
  Future<String?> getLastBluetoothPeerId();
  Future<String?> getLastBluetoothPeerName();
  Future<void> setLastBluetoothPeer({required String id, required String name});

  Future<bool> getBgPermBannerDismissed();
  Future<void> setBgPermBannerDismissed(bool value);

  Future<bool> getMusicCastNotifHintDismissed();
  Future<void> setMusicCastNotifHintDismissed(bool value);

  /// Resets VOX threshold and noise suppression to [AppSettings.defaults]
  /// and persists them, returning the restored `(vox, noiseSuppression)`
  /// pair so callers can push it into a live session.
  Future<(double voxThreshold, double noiseSuppression)> restoreVoiceDefaults();
}
