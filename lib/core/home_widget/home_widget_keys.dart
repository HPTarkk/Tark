/// Canonical identifiers for the home-screen widget bridge.
///
/// Every string in [HomeWidgetKeys] is duplicated in native code — Android
/// reads them in `widget/WidgetState.kt`, iOS in `TarkWidget/SharedState.swift`
/// — out of the shared store the `home_widget` plugin writes to
/// (SharedPreferences on Android, the App Group's UserDefaults on iOS).
///
/// Values must never change once shipped, for the same reason
/// [SettingsKeys] values can't: a widget already sitting on someone's home
/// screen keeps rendering the last published payload until the app runs
/// again, so a renamed key silently blanks it.
abstract final class HomeWidgetKeys {
  // ── Session facts ───────────────────────────────────────────────────────
  /// One of [HomeWidgetSession]'s `name`s — the single value that decides
  /// which visual state (color, glow, action button) the widget renders.
  static const session = 'wk_session';
  static const mode = 'wk_mode';
  static const callsign = 'wk_callsign';
  static const peerCount = 'wk_peers';

  /// Name of whoever is currently transmitting to us, empty when nobody is.
  static const talker = 'wk_talker';

  /// Epoch millis of the last publish — the widget greys itself out when
  /// this gets stale, so a session killed by the OS (rather than ended
  /// cleanly) can't leave a permanent "LIVE" on the home screen.
  static const updatedAt = 'wk_updated_at';

  // ── Pre-localized display strings ───────────────────────────────────────
  // Rendered by Dart rather than the native side: the app already owns the
  // fa/en ARB files, and duplicating them into Android strings.xml + an iOS
  // .strings file would mean three copies of every label drifting apart.
  static const modeLabel = 'wk_mode_label';
  static const statusLine = 'wk_status_line';
  static const actionLabel = 'wk_action_label';
  static const peersLabel = 'wk_peers_label';
  static const muteLabel = 'wk_mute_label';
  static const endLabel = 'wk_end_label';

  // ── Presentation flags ──────────────────────────────────────────────────
  static const isRtl = 'wk_rtl';
  static const isLight = 'wk_light';

  /// App-side only (the ordinary app SharedPreferences, not the widget
  /// store): the nonce of the last widget tap that was acted on, so a
  /// replayed launch intent can be recognised and dropped. See
  /// [HomeWidgetLaunch].
  static const consumedLaunchNonce = 'wk_consumed_launch_nonce';
}

/// Platform registration names, kept next to the keys they travel with.
abstract final class HomeWidgetIds {
  /// Android: the AppWidgetProvider subclass, fully qualified.
  ///
  /// Must be passed as `qualifiedAndroidName`, not `androidName` — the plugin
  /// resolves the latter as `"<applicationId>.<name>"`, which can't reach a
  /// class in the `.widget` subpackage and fails with ClassNotFoundException.
  static const androidProvider = 'com.b1101.tark.widget.TarkWidgetProvider';

  /// iOS: the `kind` string of the WidgetKit configuration, which must match
  /// `TarkWidget`'s `kind:` in TarkWidget.swift.
  static const iOSWidgetKind = 'TarkWidget';

  /// iOS: the App Group both the app and the widget extension are members
  /// of — the only channel through which an extension can read app state.
  /// Must match Runner.entitlements and TarkWidgetExtension.entitlements.
  static const appGroup = 'group.com.b1101.tark';

  /// Scheme of the deep links the widget fires back at the app. Handled in
  /// [HomeWidgetLaunch.parse].
  static const uriScheme = 'tark';
}
