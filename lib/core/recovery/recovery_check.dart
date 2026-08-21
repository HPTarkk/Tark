import 'package:flutter/foundation.dart';

import 'recovery_action.dart';

/// How a single checked-on thing is doing.
enum RecoveryStatus {
  /// Working. Nothing to do.
  ok,

  /// Working, but not the way the user probably wants — worth a look, not a
  /// stoppage. (Alone in a channel, for example: correct, just quiet.)
  warn,

  /// Broken. Something the user expects to work does not.
  bad,

  /// Not knowable right now (still starting up, or the platform can't say).
  /// Never rendered as a failure — an unknown is not bad news.
  unknown,
}

/// One line in the troubleshooting sheet: a thing the app checked, what it
/// found, and what the user can do about it.
///
/// Built by whichever feature owns the fact (the channel screen knows about
/// the mic; the transport knows about the network), because [core] cannot
/// import features. Core only knows how to draw one.
@immutable
class RecoveryCheck {
  /// What was checked, in the user's words — "Microphone", "Network".
  final String label;

  /// What was found, in one short line — "Working", "Blocked in Settings".
  /// This is the part the user actually reads, so it says the finding, not
  /// the mechanism.
  final String detail;

  final RecoveryStatus status;

  /// Fixes offered inline on this row. Empty for a healthy check.
  final List<RecoveryAction> actions;

  /// Stable machine id for diagnostics/analytics — "mic_no_frames",
  /// "route_phone_speaker". Null for checks that only ever render (nothing
  /// downstream needs to tell their transitions apart in a log); Preflight
  /// (#33) is the first caller that sets it, since its whole diagnostics
  /// requirement is a privacy-safe record of which check changed and when.
  final String? code;

  const RecoveryCheck({
    required this.label,
    required this.detail,
    required this.status,
    this.actions = const [],
    this.code,
  });

  bool get isHealthy =>
      status == RecoveryStatus.ok || status == RecoveryStatus.unknown;
}
