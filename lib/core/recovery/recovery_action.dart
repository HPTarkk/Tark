import 'package:flutter/foundation.dart';

/// Something the user can tap to try to fix a problem.
///
/// Deliberately a plain data object rather than a widget: the same action is
/// offered from a banner, from the troubleshooting sheet, and (for the
/// blocking cases) from a full-screen card, and all three must run the exact
/// same thing. Features build these; [core] only renders them.
@immutable
class RecoveryAction {
  /// Short, imperative, and in the user's words — "Turn Wi-Fi on", not
  /// "rebind sockets".
  final String label;

  /// Runs the fix. May open a system screen, retry a connection, or re-ask
  /// for a permission; the caller does not care which.
  final Future<void> Function() run;

  /// The one action most likely to work. Rendered filled; everything else is
  /// an outline. At most one per set.
  final bool isPrimary;

  const RecoveryAction({
    required this.label,
    required this.run,
    this.isPrimary = false,
  });
}
