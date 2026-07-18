import 'package:shared_preferences/shared_preferences.dart';

import '../config/quick_access_config.dart';
import 'app_settings.dart';
import 'noise_suppression_engine.dart';
import 'settings_keys.dart';

/// Data-layer representation of [AppSettings]: adds JSON (de)serialization
/// and SharedPreferences loading on top of the plain domain entity.
class SettingsModel extends AppSettings {
  const SettingsModel({
    required super.myName,
    required super.voxThreshold,
    required super.noiseSuppression,
    required super.noiseSuppressionEngine,
    required super.musicGain,
    required super.targetBufferMs,
    required super.autoReconnectEnabled,
    required super.skipSplash,
    required super.quickAccessEnabled,
    required super.usageTipsShown,
  });

  factory SettingsModel.fromAppSettings(AppSettings s) => SettingsModel(
    myName: s.myName,
    voxThreshold: s.voxThreshold,
    noiseSuppression: s.noiseSuppression,
    noiseSuppressionEngine: s.noiseSuppressionEngine,
    musicGain: s.musicGain,
    targetBufferMs: s.targetBufferMs,
    autoReconnectEnabled: s.autoReconnectEnabled,
    skipSplash: s.skipSplash,
    quickAccessEnabled: s.quickAccessEnabled,
    usageTipsShown: s.usageTipsShown,
  );

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    final d = AppSettings.defaults();
    return SettingsModel(
      myName: json['myName'] as String? ?? d.myName,
      voxThreshold:
          (json['voxThreshold'] as num?)?.toDouble() ?? d.voxThreshold,
      noiseSuppression:
          (json['noiseSuppression'] as num?)?.toDouble() ?? d.noiseSuppression,
      noiseSuppressionEngine: json['noiseSuppressionEngine'] == null
          ? d.noiseSuppressionEngine
          : NoiseSuppressionEngine.fromName(
              json['noiseSuppressionEngine'] as String?,
            ),
      musicGain: (json['musicGain'] as num?)?.toDouble() ?? d.musicGain,
      targetBufferMs:
          (json['targetBufferMs'] as num?)?.toInt() ?? d.targetBufferMs,
      autoReconnectEnabled:
          json['autoReconnectEnabled'] as bool? ?? d.autoReconnectEnabled,
      skipSplash: json['skipSplash'] as bool? ?? d.skipSplash,
      quickAccessEnabled:
          json['quickAccessEnabled'] as bool? ?? d.quickAccessEnabled,
      usageTipsShown: json['usageTipsShown'] as bool? ?? d.usageTipsShown,
    );
  }

  Map<String, dynamic> toJson() => {
    'myName': myName,
    'voxThreshold': voxThreshold,
    'noiseSuppression': noiseSuppression,
    'noiseSuppressionEngine': noiseSuppressionEngine.name,
    'musicGain': musicGain,
    'targetBufferMs': targetBufferMs,
    'autoReconnectEnabled': autoReconnectEnabled,
    'skipSplash': skipSplash,
    'quickAccessEnabled': quickAccessEnabled,
    'usageTipsShown': usageTipsShown,
  };

  /// Reads every field from [prefs], falling back to [AppSettings.defaults]
  /// per-field so a partially-populated store (e.g. an older app version)
  /// still yields a fully valid settings object.
  factory SettingsModel.fromPrefs(SharedPreferences prefs) {
    final d = AppSettings.defaults();
    return SettingsModel(
      myName: prefs.getString(SettingsKeys.userName) ?? d.myName,
      voxThreshold:
          prefs.getDouble(SettingsKeys.voxThreshold) ?? d.voxThreshold,
      noiseSuppression:
          prefs.getDouble(SettingsKeys.noiseSuppression) ?? d.noiseSuppression,
      noiseSuppressionEngine:
          prefs.getString(SettingsKeys.noiseSuppressionEngine) == null
          ? d.noiseSuppressionEngine
          : NoiseSuppressionEngine.fromName(
              prefs.getString(SettingsKeys.noiseSuppressionEngine),
            ),
      musicGain: prefs.getDouble(SettingsKeys.musicGain) ?? d.musicGain,
      targetBufferMs:
          prefs.getInt(SettingsKeys.targetBufferMs) ?? d.targetBufferMs,
      autoReconnectEnabled:
          prefs.getBool(SettingsKeys.autoReconnectEnabled) ??
          d.autoReconnectEnabled,
      skipSplash: prefs.getBool(SettingsKeys.skipSplash) ?? d.skipSplash,
      // Owned by QuickAccessPrefs (core/config/quick_access_config.dart),
      // not a SettingsKeys entry — avoid a second key for the same value.
      quickAccessEnabled:
          prefs.getBool(QuickAccessPrefs.enabled) ?? d.quickAccessEnabled,
      usageTipsShown:
          prefs.getBool(SettingsKeys.usageTipsShown) ?? d.usageTipsShown,
    );
  }
}
