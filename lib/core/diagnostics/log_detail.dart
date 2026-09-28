/// How much of what the user does goes into the diagnostic log (Settings >
/// Advanced > Diagnostics > Log level).
///
/// Only the user-activity lines written by `ScreenLog` depend on this. The
/// lifecycle, connection, audio and error lines are written at every level,
/// exactly as they were before the levels existed.
enum LogDetail {
  /// The log as it has always been: no user-activity lines at all. The
  /// default, so nobody's log grows unless they asked for it.
  standard('standard'),

  /// Adds every page, sheet and dialog opened or closed, tabs switched
  /// inside a screen, and taps on the buttons that start or end something.
  screens('screens'),

  /// Adds every tap anywhere and every settings change.
  everything('everything');

  const LogDetail(this.key);

  /// What is stored in preferences. Stable: renaming a value must not reset
  /// anyone's choice.
  final String key;

  static const LogDetail fallback = LogDetail.standard;

  static LogDetail fromKey(String? key) {
    for (final value in values) {
      if (value.key == key) return value;
    }
    return fallback;
  }
}
