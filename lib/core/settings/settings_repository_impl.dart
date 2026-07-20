import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

<<<<<<< HEAD
import '../config/onboarding_config.dart';
=======
>>>>>>> 1a1b9a0907d416f3f997a374d5196c05166a4b0e
import '../config/quick_access_config.dart';
import 'app_settings.dart';
import 'noise_suppression_engine.dart';
import 'settings_keys.dart';
import 'settings_model.dart';
import 'settings_repository.dart';

<<<<<<< HEAD
/// Thin SharedPreferences-backed [SettingsRepository]. The prefs instance is
/// resolved exactly once per process — pre-resolved by DI for the app, and
/// by each entrypoint (main.dart, main_guest.dart) for the code that runs
/// before/without DI — and injected here, so no method ever goes back
/// through SharedPreferences.getInstance().
@LazySingleton(as: SettingsRepository)
class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._prefs);

  final SharedPreferences _prefs;

  // Static because instances are interchangeable stateless facades over the
  // process-global SharedPreferences (the DI singleton plus the guest
  // composition's direct construction) — a write through any instance must
  // reach subscribers of every other one.
  static final _myNameController = StreamController<String>.broadcast();

  @override
  Future<AppSettings> loadAll() async => SettingsModel.fromPrefs(_prefs);

  @override
  Future<String> getMyName() async =>
      _prefs.getString(SettingsKeys.userName) ?? AppSettings.defaults().myName;

  @override
  Future<void> setMyName(String value) async {
    await _prefs.setString(SettingsKeys.userName, value);
=======
/// Thin SharedPreferences-backed [SettingsRepository]. No constructor
/// dependencies, so code that runs before DI is configured (LocaleService,
/// ThemeService in main.dart) can construct this directly instead of only
/// through GetIt.
@LazySingleton(as: SettingsRepository)
class SettingsRepositoryImpl implements SettingsRepository {
  // Static because instances are interchangeable stateless facades over the
  // process-global SharedPreferences (the DI singleton plus the direct
  // constructions noted above) — a write through any instance must reach
  // subscribers of every other one.
  static final _myNameController = StreamController<String>.broadcast();

  @override
  Future<AppSettings> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsModel.fromPrefs(prefs);
  }

  @override
  Future<String> getMyName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(SettingsKeys.userName) ??
        AppSettings.defaults().myName;
  }

  @override
  Future<void> setMyName(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SettingsKeys.userName, value);
>>>>>>> 1a1b9a0907d416f3f997a374d5196c05166a4b0e
    _myNameController.add(value);
  }

  @override
  Stream<String> get myNameChanges => _myNameController.stream;

  @override
<<<<<<< HEAD
  Future<double> getVoxThreshold() async =>
      _prefs.getDouble(SettingsKeys.voxThreshold) ??
      AppSettings.defaults().voxThreshold;

  @override
  Future<void> setVoxThreshold(double value) =>
      _prefs.setDouble(SettingsKeys.voxThreshold, value);

  @override
  Future<double> getNoiseSuppression() async =>
      _prefs.getDouble(SettingsKeys.noiseSuppression) ??
      AppSettings.defaults().noiseSuppression;

  @override
  Future<void> setNoiseSuppression(double value) =>
      _prefs.setDouble(SettingsKeys.noiseSuppression, value);

  @override
  Future<NoiseSuppressionEngine> getNoiseSuppressionEngine() async {
    final stored = _prefs.getString(SettingsKeys.noiseSuppressionEngine);
=======
  Future<double> getVoxThreshold() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(SettingsKeys.voxThreshold) ??
        AppSettings.defaults().voxThreshold;
  }

  @override
  Future<void> setVoxThreshold(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(SettingsKeys.voxThreshold, value);
  }

  @override
  Future<double> getNoiseSuppression() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(SettingsKeys.noiseSuppression) ??
        AppSettings.defaults().noiseSuppression;
  }

  @override
  Future<void> setNoiseSuppression(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(SettingsKeys.noiseSuppression, value);
  }

  @override
  Future<NoiseSuppressionEngine> getNoiseSuppressionEngine() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(SettingsKeys.noiseSuppressionEngine);
>>>>>>> 1a1b9a0907d416f3f997a374d5196c05166a4b0e
    // NoiseSuppressionEngine.fromName's own fallback is spectral, not the
    // real default — go through AppSettings.defaults() like every other
    // getter here so an unset value gets the actual current default.
    if (stored == null) return AppSettings.defaults().noiseSuppressionEngine;
    return NoiseSuppressionEngine.fromName(stored);
  }

  @override
<<<<<<< HEAD
  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine value) =>
      _prefs.setString(SettingsKeys.noiseSuppressionEngine, value.name);

  @override
  Future<double> getMusicGain() async =>
      _prefs.getDouble(SettingsKeys.musicGain) ??
      AppSettings.defaults().musicGain;

  @override
  Future<void> setMusicGain(double value) =>
      _prefs.setDouble(SettingsKeys.musicGain, value);

  @override
  Future<int> getTargetBufferMs() async =>
      _prefs.getInt(SettingsKeys.targetBufferMs) ??
      AppSettings.defaults().targetBufferMs;

  @override
  Future<void> setTargetBufferMs(int value) =>
      _prefs.setInt(SettingsKeys.targetBufferMs, value);

  @override
  Future<bool> getAutoReconnectEnabled() async =>
      _prefs.getBool(SettingsKeys.autoReconnectEnabled) ??
      AppSettings.defaults().autoReconnectEnabled;

  @override
  Future<void> setAutoReconnectEnabled(bool value) =>
      _prefs.setBool(SettingsKeys.autoReconnectEnabled, value);

  @override
  Future<bool> getSkipSplash() async =>
      _prefs.getBool(SettingsKeys.skipSplash) ??
      AppSettings.defaults().skipSplash;

  @override
  Future<void> setSkipSplash(bool value) =>
      _prefs.setBool(SettingsKeys.skipSplash, value);

  @override
  Future<bool> getQuickAccessEnabled() async =>
      _prefs.getBool(QuickAccessPrefs.enabled) ??
      AppSettings.defaults().quickAccessEnabled;

  @override
  Future<void> setQuickAccessEnabled(bool value) =>
      _prefs.setBool(QuickAccessPrefs.enabled, value);

  @override
  Future<bool> getUsageTipsShown() async =>
      _prefs.getBool(SettingsKeys.usageTipsShown) ??
      AppSettings.defaults().usageTipsShown;

  @override
  Future<void> setUsageTipsShown(bool value) =>
      _prefs.setBool(SettingsKeys.usageTipsShown, value);

  @override
  Future<String?> getLastBluetoothPeerId() async =>
      _prefs.getString(SettingsKeys.btLastPeerId);

  @override
  Future<String?> getLastBluetoothPeerName() async =>
      _prefs.getString(SettingsKeys.btLastPeerName);
=======
  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SettingsKeys.noiseSuppressionEngine, value.name);
  }

  @override
  Future<double> getMusicGain() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(SettingsKeys.musicGain) ??
        AppSettings.defaults().musicGain;
  }

  @override
  Future<void> setMusicGain(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(SettingsKeys.musicGain, value);
  }

  @override
  Future<int> getTargetBufferMs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(SettingsKeys.targetBufferMs) ??
        AppSettings.defaults().targetBufferMs;
  }

  @override
  Future<void> setTargetBufferMs(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(SettingsKeys.targetBufferMs, value);
  }

  @override
  Future<bool> getAutoReconnectEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SettingsKeys.autoReconnectEnabled) ??
        AppSettings.defaults().autoReconnectEnabled;
  }

  @override
  Future<void> setAutoReconnectEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.autoReconnectEnabled, value);
  }

  @override
  Future<bool> getSkipSplash() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SettingsKeys.skipSplash) ??
        AppSettings.defaults().skipSplash;
  }

  @override
  Future<void> setSkipSplash(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.skipSplash, value);
  }

  @override
  Future<bool> getQuickAccessEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(QuickAccessPrefs.enabled) ??
        AppSettings.defaults().quickAccessEnabled;
  }

  @override
  Future<void> setQuickAccessEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(QuickAccessPrefs.enabled, value);
  }

  @override
  Future<bool> getUsageTipsShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SettingsKeys.usageTipsShown) ??
        AppSettings.defaults().usageTipsShown;
  }

  @override
  Future<void> setUsageTipsShown(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.usageTipsShown, value);
  }

  @override
  Future<String?> getLastBluetoothPeerId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(SettingsKeys.btLastPeerId);
  }

  @override
  Future<String?> getLastBluetoothPeerName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(SettingsKeys.btLastPeerName);
  }
>>>>>>> 1a1b9a0907d416f3f997a374d5196c05166a4b0e

  @override
  Future<void> setLastBluetoothPeer({
    required String id,
    required String name,
  }) async {
<<<<<<< HEAD
    await _prefs.setString(SettingsKeys.btLastPeerId, id);
    await _prefs.setString(SettingsKeys.btLastPeerName, name);
  }

  @override
  Future<String?> getLastBluetoothRole() async =>
      _prefs.getString(SettingsKeys.btLastRole);

  @override
  Future<void> setLastBluetoothRole(String role) =>
      _prefs.setString(SettingsKeys.btLastRole, role);

  @override
  Future<bool> getBgPermBannerDismissed() async =>
      _prefs.getBool(SettingsKeys.bgPermBannerDismissed) ?? false;

  @override
  Future<void> setBgPermBannerDismissed(bool value) =>
      _prefs.setBool(SettingsKeys.bgPermBannerDismissed, value);

  @override
  Future<bool> getMusicCastNotifHintDismissed() async =>
      _prefs.getBool(SettingsKeys.musicCastNotifHintDismissed) ?? false;

  @override
  Future<void> setMusicCastNotifHintDismissed(bool value) =>
      _prefs.setBool(SettingsKeys.musicCastNotifHintDismissed, value);

  @override
  Future<void> setHasLaunchedBefore(bool value) =>
      _prefs.setBool(QuickAccessPrefs.hasLaunchedBefore, value);

  @override
  Future<void> setOnboardingCompleted(bool value) =>
      _prefs.setBool(OnboardingPrefs.completed, value);
=======
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SettingsKeys.btLastPeerId, id);
    await prefs.setString(SettingsKeys.btLastPeerName, name);
  }

  @override
  Future<bool> getBgPermBannerDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SettingsKeys.bgPermBannerDismissed) ?? false;
  }

  @override
  Future<void> setBgPermBannerDismissed(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.bgPermBannerDismissed, value);
  }

  @override
  Future<bool> getMusicCastNotifHintDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(SettingsKeys.musicCastNotifHintDismissed) ?? false;
  }

  @override
  Future<void> setMusicCastNotifHintDismissed(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(SettingsKeys.musicCastNotifHintDismissed, value);
  }
>>>>>>> 1a1b9a0907d416f3f997a374d5196c05166a4b0e

  @override
  Future<(double, double, int)> restoreVoiceDefaults() async {
    final defaults = AppSettings.defaults();
    await setVoxThreshold(defaults.voxThreshold);
    await setNoiseSuppression(defaults.noiseSuppression);
    await setTargetBufferMs(defaults.targetBufferMs);
    return (
      defaults.voxThreshold,
      defaults.noiseSuppression,
      defaults.targetBufferMs,
    );
  }
}
