import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/quick_access_config.dart';
import 'app_settings.dart';
import 'settings_keys.dart';
import 'settings_model.dart';
import 'settings_repository.dart';

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
    _myNameController.add(value);
  }

  @override
  Stream<String> get myNameChanges => _myNameController.stream;

  @override
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

  @override
  Future<void> setLastBluetoothPeer({
    required String id,
    required String name,
  }) async {
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

  @override
  Future<(double, double)> restoreVoiceDefaults() async {
    final defaults = AppSettings.defaults();
    await setVoxThreshold(defaults.voxThreshold);
    await setNoiseSuppression(defaults.noiseSuppression);
    return (defaults.voxThreshold, defaults.noiseSuppression);
  }
}
