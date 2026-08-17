import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/log_budget.dart';
import 'app_settings.dart';
import 'noise_suppression_engine.dart';
import 'settings_keys.dart';
import 'vox_margin.dart';

/// Data-layer representation of [AppSettings]: adds JSON (de)serialization
/// and SharedPreferences loading on top of the plain domain entity.
class SettingsModel extends AppSettings {
  const SettingsModel({
    required super.myName,
    required super.voxMargin,
    required super.noiseSuppression,
    required super.noiseSuppressionEngine,
    required super.musicGain,
    required super.targetBufferMs,
    required super.ridingPreset,
    required super.autoReconnectEnabled,
    required super.skipSplash,
    required super.usageTipsShown,
    required super.analyticsEnabled,
    required super.logMaxBytes,
  });

  factory SettingsModel.fromAppSettings(AppSettings s) => SettingsModel(
    myName: s.myName,
    voxMargin: s.voxMargin,
    noiseSuppression: s.noiseSuppression,
    noiseSuppressionEngine: s.noiseSuppressionEngine,
    musicGain: s.musicGain,
    targetBufferMs: s.targetBufferMs,
    ridingPreset: s.ridingPreset,
    autoReconnectEnabled: s.autoReconnectEnabled,
    skipSplash: s.skipSplash,
    usageTipsShown: s.usageTipsShown,
    analyticsEnabled: s.analyticsEnabled,
    logMaxBytes: s.logMaxBytes,
  );

  factory SettingsModel.fromJson(Map<String, dynamic> json) {
    final d = AppSettings.defaults();
    return SettingsModel(
      myName: json['myName'] as String? ?? d.myName,
      // The legacy name carried an absolute threshold, so it is translated
      // rather than read straight — same rule as the preference key.
      voxMargin:
          (json['voxMargin'] as num?)?.toDouble() ??
          (json['voxThreshold'] == null
              ? d.voxMargin
              : VoxMargin.fromLegacyThreshold(
                  (json['voxThreshold'] as num).toDouble(),
                )),
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
      ridingPreset: json['ridingPreset'] as bool? ?? d.ridingPreset,
      autoReconnectEnabled:
          json['autoReconnectEnabled'] as bool? ?? d.autoReconnectEnabled,
      skipSplash: json['skipSplash'] as bool? ?? d.skipSplash,
      usageTipsShown: json['usageTipsShown'] as bool? ?? d.usageTipsShown,
      analyticsEnabled:
          json['analyticsEnabled'] as bool? ?? d.analyticsEnabled,
      // Clamped, not just defaulted: a value from a build with a different
      // range must land inside this one's rather than uncapping the log.
      logMaxBytes: LogBudget.clamp(
        (json['logMaxBytes'] as num?)?.toInt() ?? d.logMaxBytes,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'myName': myName,
    'voxMargin': voxMargin,
    'noiseSuppression': noiseSuppression,
    'noiseSuppressionEngine': noiseSuppressionEngine.name,
    'musicGain': musicGain,
    'targetBufferMs': targetBufferMs,
    'ridingPreset': ridingPreset,
    'autoReconnectEnabled': autoReconnectEnabled,
    'skipSplash': skipSplash,
    'usageTipsShown': usageTipsShown,
    'analyticsEnabled': analyticsEnabled,
    'logMaxBytes': logMaxBytes,
  };

  /// Reads the VOX margin, translating the absolute-threshold key that builds
  /// predating the reframe wrote — see [VoxMargin.fromLegacyThreshold].
  ///
  /// Shared with `SettingsRepositoryImpl.getVoxMargin` so `loadAll` and the
  /// single getter cannot disagree about a migrated install; a disagreement
  /// there draws one value on the settings page while the engine runs another.
  ///
  /// **Read-through, never rewritten.** Translating on every read rather than
  /// converting once and writing back keeps the read free of side effects
  /// (no write racing a concurrent read, nothing half-finished if the process
  /// dies mid-migration) and leaves the old key intact, so a downgrade to an
  /// older build still finds its own setting. The first touch of the slider
  /// writes the new key, and the legacy value is never consulted again.
  static double readVoxMargin(SharedPreferences prefs) {
    final stored = prefs.getDouble(SettingsKeys.voxMargin);
    if (stored != null) return stored;
    final legacy = prefs.getDouble(SettingsKeys.legacyVoxThreshold);
    if (legacy != null) return VoxMargin.fromLegacyThreshold(legacy);
    return AppSettings.defaults().voxMargin;
  }

  /// Reads every field from [prefs], falling back to [AppSettings.defaults]
  /// per-field so a partially-populated store (e.g. an older app version)
  /// still yields a fully valid settings object.
  factory SettingsModel.fromPrefs(SharedPreferences prefs) {
    final d = AppSettings.defaults();
    return SettingsModel(
      myName: prefs.getString(SettingsKeys.userName) ?? d.myName,
      voxMargin: readVoxMargin(prefs),
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
      ridingPreset:
          prefs.getBool(SettingsKeys.ridingPreset) ?? d.ridingPreset,
      autoReconnectEnabled:
          prefs.getBool(SettingsKeys.autoReconnectEnabled) ??
          d.autoReconnectEnabled,
      skipSplash: prefs.getBool(SettingsKeys.skipSplash) ?? d.skipSplash,
      usageTipsShown:
          prefs.getBool(SettingsKeys.usageTipsShown) ?? d.usageTipsShown,
      analyticsEnabled:
          prefs.getBool(SettingsKeys.analyticsEnabled) ?? d.analyticsEnabled,
      logMaxBytes: LogBudget.clamp(
        prefs.getInt(SettingsKeys.logMaxBytes) ?? d.logMaxBytes,
      ),
    );
  }
}
