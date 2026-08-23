/// Canonical SharedPreferences key strings for every persisted app setting.
///
/// Values must never change once shipped — they're read back from existing
/// installs. New keys may be added freely; existing ones are permanent.
abstract final class SettingsKeys {
  // Owned by SettingsRepository (see settings_repository_impl.dart).
  static const userName = 'user_name';

  /// How far above the measured background the VOX gate sits — see [VoxMargin].
  static const voxMargin = 'vox_margin';

  /// The absolute-RMS VOX threshold this replaced. Still read (never written)
  /// so an install that predates the reframe keeps the setting it chose, via
  /// `VoxMargin.fromLegacyThreshold`. Kept as a read-through rather than
  /// rewritten in place, which also means a downgrade to an older build finds
  /// its own key intact.
  static const legacyVoxThreshold = 'vox_threshold';
  static const noiseSuppression = 'noise_suppression';
  static const noiseSuppressionEngine = 'noise_suppression_engine';
  static const musicGain = 'music_gain';
  static const targetBufferMs = 'target_buffer_ms';
  static const ridingPreset = 'riding_preset';
  static const autoReconnectEnabled = 'auto_reconnect_enabled';
  static const skipSplash = 'skip_splash';
  static const usageTipsShown = 'usage_tips_shown';
  static const analyticsEnabled = 'analytics_enabled';
  static const logMaxBytes = 'log_max_bytes';

  /// #31 — whether Shared Music automatically ducks while someone is
  /// talking. See [AppSettings.smartMusicDuckingEnabled].
  static const smartMusicDuckingEnabled = 'smart_music_ducking_enabled';

  /// Whether this build may negotiate up to the HD Voice (24kHz) profile.
  /// See [AppSettings.hdVoiceEnabled] and `AudioFormatProfile.hdVoiceEnabled`.
  static const hdVoiceEnabled = 'hd_voice_enabled';

  /// Whether this build may negotiate up to an HD Shared Music (48kHz)
  /// profile. See [AppSettings.hdMusicEnabled] and
  /// `AudioFormatProfile.hdMusicEnabled`.
  static const hdMusicEnabled = 'hd_music_enabled';

  // Owned by their existing dedicated services/widgets — kept here too so
  // every persisted key in the app has exactly one string literal, even
  // where SettingsRepository isn't the reader/writer.
  /// The transport currently in effect. Written by every path that picks one —
  /// the advisor on the landing page as well as the manual picker — because
  /// the DI factory reads it synchronously at cold start to decide which
  /// TransferRepository to hand out. It is a record of what happened, not of
  /// what the user asked for; [transportPin] is the latter.
  static const transportMode = 'transport_mode';

  /// A transport pinned by hand in Advanced settings. Absent (or `auto`) means
  /// automatic, which is the default and what an install that never opens
  /// Advanced settings runs forever. Kept apart from [transportMode] so that
  /// choosing automatic does not have to invent an effective mode to store,
  /// and so an install that predates the pin reads as automatic rather than as
  /// having pinned whatever it happened to be using.
  static const transportPin = 'transport_pin';
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
