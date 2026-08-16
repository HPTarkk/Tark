import 'package:equatable/equatable.dart';

/// Unified connection state surfaced by every [TransferRepository]
/// implementation, replacing the old plain `bool` "is connected" signal.
///
/// Ordered as a recovery ladder, worst news last:
///
/// ```
/// healthy → degraded → reconnecting → renegotiating → down
/// ```
///
/// A link does not fall off the top of that ladder to the bottom. It climbs,
/// and most trips stop at [degraded] — which is the point. A phone in a pocket
/// on a motorcycle loses its link for two or three seconds constantly (a
/// passing truck, a hand over the antenna, the AP re-keying), and the old
/// three-state model had nothing to say about that except "reconnecting",
/// which lit the banner and played the link-lost sound for something that had
/// already fixed itself by the time the user looked.
///
/// [down] specifically means "not currently retrying automatically" — either
/// auto-reconnect is turned off, or a transport (Guest/WebRTC) has exhausted
/// its bounded retry attempts — so the UI should offer a manual retry.
enum ConnectionHealthStatus {
  /// Traffic is flowing.
  healthy,

  /// Something broke and is being repaired, but the session is still live and
  /// the user is deliberately not told. The first rung, and the one almost
  /// every real-world drop is resolved on.
  degraded,

  /// Repair did not take on the first attempt, so this is now worth showing:
  /// sockets are being rebound on a backoff schedule.
  reconnecting,

  /// Rebinding on the network we thought we were on has stopped working, so
  /// the assumptions underneath it are being thrown away — addresses
  /// re-resolved, broadcast narrowing dropped, discovery reopened to every
  /// interface. Still automatic, still recoverable.
  renegotiating,

  /// Nothing further will be attempted without the user.
  down,
}

/// The link health plus, while [ConnectionHealthStatus.reconnecting] under an
/// automatic backoff schedule, *when* the next attempt fires — so the banner
/// can show a Telegram-style live countdown that grows with each failed try
/// (the exponential backoff) and resets on a successful reconnect.
///
/// [nextRetryAt] / [retryDelay] are null when a rebind is being attempted right
/// now (indeterminate), when down, when healthy, or for a transport that
/// doesn't expose its schedule (Bluetooth today).
class ConnectionHealth extends Equatable {
  const ConnectionHealth(this.status, {this.nextRetryAt, this.retryDelay});

  const ConnectionHealth.healthy()
    : status = ConnectionHealthStatus.healthy,
      nextRetryAt = null,
      retryDelay = null;

  const ConnectionHealth.down()
    : status = ConnectionHealthStatus.down,
      nextRetryAt = null,
      retryDelay = null;

  /// A fault is being repaired quietly. Carries no schedule: the repair is
  /// happening now, and there is nothing for the user to count down to
  /// because they are not being shown anything.
  const ConnectionHealth.degraded()
    : status = ConnectionHealthStatus.degraded,
      nextRetryAt = null,
      retryDelay = null;

  /// Rebinding stopped working, so the network assumptions are being rebuilt.
  const ConnectionHealth.renegotiating({this.nextRetryAt, this.retryDelay})
    : status = ConnectionHealthStatus.renegotiating;

  /// Reconnecting. Pass [nextRetryAt] + [retryDelay] to drive the countdown;
  /// omit both for the indeterminate "attempting now" phase.
  const ConnectionHealth.reconnecting({this.nextRetryAt, this.retryDelay})
    : status = ConnectionHealthStatus.reconnecting;

  final ConnectionHealthStatus status;

  /// Wall-clock instant the next automatic reconnect attempt is scheduled for.
  final DateTime? nextRetryAt;

  /// Full length of the current backoff wait (for a depleting progress bar).
  final Duration? retryDelay;

  bool get isHealthy => status == ConnectionHealthStatus.healthy;

  /// Whether the session should still be presented to the user as up.
  ///
  /// The distinction [isHealthy] cannot draw. A degraded link is not healthy —
  /// something is being repaired — but announcing it costs more than it is
  /// worth: the banner and the link-lost sound are for a link the user has to
  /// do something about, and a two-second dip that healed itself is not one.
  /// Everything user-facing keys on this; only the transport's own repair
  /// logic keys on [isHealthy].
  bool get isLive =>
      status == ConnectionHealthStatus.healthy ||
      status == ConnectionHealthStatus.degraded;

  /// Whether recovery is still running on its own. False only for [down],
  /// which is the one state that needs the user.
  bool get isRecoverable => status != ConnectionHealthStatus.down;

  @override
  List<Object?> get props => [status, nextRetryAt, retryDelay];
}
