import '../entity/connection_health.dart';

/// How far a run of failed reconnect attempts has escalated, and what to tell
/// the user at that point.
///
/// ## Why a ladder rather than one "reconnecting" state
///
/// A link that fails is not one situation. A phone in a pocket at speed loses
/// its Wi-Fi for two or three seconds constantly — a truck passes, a hand
/// covers the antenna, the AP re-keys — and the socket is back before anyone
/// could have looked at the screen. Reporting that identically to a link that
/// has been rebinding onto a dead network for a minute meant the banner and
/// the link-lost sound fired many times per ride for nothing, which is how
/// users learn to ignore both.
///
/// So the first attempt is served silently ([ConnectionHealthStatus.degraded])
/// and only a failure that outlives it becomes news. Past
/// [rebindAttempts] the diagnosis changes rather than merely the wording: if
/// binding to the network we believe we are on has not worked several times
/// over, the belief is the suspect, and the caller is told to throw it away
/// ([shouldRenegotiate]).
///
/// Pure bookkeeping — the caller owns the backoff clock and does the repairing
/// — so this is testable without a socket.
class RecoveryLadder {
  RecoveryLadder({this.quietAttempts = 1, this.rebindAttempts = 3})
    : assert(quietAttempts < rebindAttempts);

  /// Attempts served quietly before the user is told anything. One, which at
  /// the opening backoff delay is about four seconds — deliberately just past
  /// the dip this exists to absorb.
  final int quietAttempts;

  /// Attempts spent rebinding on the network we believe we are on, before that
  /// belief is itself treated as the fault.
  final int rebindAttempts;

  int _attempts = 0;

  /// Consecutive failed attempts since traffic last flowed.
  int get attempts => _attempts;

  /// Records that another attempt is about to be made.
  void escalate() => _attempts++;

  /// Traffic is flowing again, or the session ended: start over on the quiet
  /// rung so the next hiccup is repaired without a banner.
  void reset() => _attempts = 0;

  /// Whether the caller should discard what it believes about the network
  /// before the next bind.
  bool get shouldRenegotiate => _attempts > rebindAttempts;

  /// The health to report right now. [delay] is the scheduled wait before the
  /// next attempt, folded in so the banner can count down to it; pass null
  /// while an attempt is actually running, which leaves the rung unchanged and
  /// only drops the countdown.
  ConnectionHealth rung(Duration? delay) {
    final at = delay == null ? null : DateTime.now().add(delay);
    if (_attempts <= quietAttempts) return const ConnectionHealth.degraded();
    if (_attempts <= rebindAttempts) {
      return ConnectionHealth.reconnecting(nextRetryAt: at, retryDelay: delay);
    }
    return ConnectionHealth.renegotiating(nextRetryAt: at, retryDelay: delay);
  }
}
