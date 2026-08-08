/// Canonical SharedPreferences key strings for every persisted app setting.
///
/// Values must never change once shipped — they're read back from existing
/// installs. New keys may be added freely; existing ones are permanent.
abstract final class SettingsKeys {
  // Owned by SettingsRepository (see settings_repository_impl.dart).
  static const userName = 'user_name';
  static const voxThreshold = 'vox_threshold';
  static const noiseSuppression = 'noise_suppression';
  static const noiseSuppressionEngine = 'noise_suppression_engine';
  static const musicGain = 'music_gain';
  static const targetBufferMs = 'target_buffer_ms';
  static const autoReconnectEnabled = 'auto_reconnect_enabled';
  static const skipSplash = 'skip_splash';
  static const usageTipsShown = 'usage_tips_shown';
  static const analyticsEnabled = 'analytics_enabled';
  static const logMaxBytes = 'log_max_bytes';

  // Owned by their existing dedicated services/widgets — kept here too so
  // every persisted key in the app has exactly one string literal, even
  // where SettingsRepository isn't the reader/writer.
  static const transportMode = 'transport_mode';
  static const appLocale = 'app_locale';
  static const appTheme = 'app_theme';
  static const bgPermBannerDismissed = 'bg_perm_banner_dismissed';
  static const btLastPeerId = 'bt_last_peer_id';
  static const btLastPeerName = 'bt_last_peer_name';
  static const btLastRole = 'bt_last_role';
  static const musicCastNotifHintDismissed = 'music_cast_notif_hint_dismissed';
  static const sfxEnabled = 'sfx_enabled';

  // Owned by EntitlementStore (see core/entitlement/). Never write these
  // from anywhere else — the paid boundary has exactly one writer.
  static const entitlementSource = 'entitlement_source';
  static const entitlementExpiresAt = 'entitlement_expires_at';
  static const trialStartedAt = 'trial_started_at';

  /// Highest wall-clock instant ever observed, in epoch ms. Guards the trial
  /// against a device date wound backwards; see EntitlementStoreImpl.now.
  static const clockHighWaterMark = 'clock_high_water_mark';
}
