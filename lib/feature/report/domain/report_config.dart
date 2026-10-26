import 'package:flutter/foundation.dart';

/// Build-time switch for member profiles, local mute and abuse reports.
///
/// Off by default: it is held back until Cafe Bazaar answers the appeal on
/// its user-content rule. Turn it on for a build or a run with:
///
///   flutter run --dart-define=TARK_MEMBER_REPORT=true
///
/// While it is off, member rows are not tappable, and every mute reads as
/// "not muted" so a mute saved by a build that had it on can never silence
/// somebody with no way to undo it.
abstract final class ReportConfig {
  static const bool _built = bool.fromEnvironment('TARK_MEMBER_REPORT');

  @visibleForTesting
  static bool? debugOverride;

  static bool get enabled => debugOverride ?? _built;
}
