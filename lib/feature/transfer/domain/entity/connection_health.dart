import 'package:equatable/equatable.dart';

/// Unified connection state surfaced by every [TransferRepository]
/// implementation, replacing the old plain `bool` "is connected" signal.
///
/// [down] specifically means "not currently retrying automatically" — either
/// auto-reconnect is turned off, or a transport (Guest/WebRTC) has exhausted
/// its bounded retry attempts — so the UI should offer a manual retry.
enum ConnectionHealthStatus { healthy, reconnecting, down }

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

  @override
  List<Object?> get props => [status, nextRetryAt, retryDelay];
}
