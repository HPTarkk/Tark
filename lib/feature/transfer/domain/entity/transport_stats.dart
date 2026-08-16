import 'package:equatable/equatable.dart';

/// What a transport knows about how well it is carrying traffic, sampled by
/// whoever wants to grade the link.
///
/// Counters are **cumulative for the life of the session**, not windowed. The
/// consumer subtracts its own previous reading to get a rate over whatever
/// window it cares about, which is the same arrangement the transport's own
/// diagnostic log line already uses for packet counts. A windowed counter
/// would have to pick one window and reset it on read, and two consumers
/// reading it would then silently steal each other's numbers.
class TransportStats extends Equatable {
  const TransportStats({
    this.sendFailing = false,
    this.unicastUnconfirmed = false,
    this.rtt,
    this.staleEpochDrops = 0,
    this.duplicateRouteDrops = 0,
    this.blockedSends = 0,
    this.peerCount = 0,
  });

  /// Nothing to report — what a transport with no such concept returns.
  static const none = TransportStats();

  /// Every unicast target has been failing for longer than the grace.
  final bool sendFailing;

  /// A peer we can plainly hear has stopped answering pings on the unicast
  /// path — so our audio, which travels unicast-only, is not reaching it even
  /// though every other signal says the link is fine. See `PeerPingTracker`.
  final bool unicastUnconfirmed;

  /// Last measured round trip to a peer. Null until a pong has been matched to
  /// the ping that caused it — an unanswered link has no latency to report,
  /// and reporting the last known figure would describe a path that is gone.
  final Duration? rtt;

  /// Packets dropped as belonging to a sender's previous join.
  final int staleEpochDrops;

  /// Packets dropped as a second copy arriving by another route.
  final int duplicateRouteDrops;

  /// Datagrams the socket refused to queue.
  final int blockedSends;

  /// Peers currently being heard from.
  final int peerCount;

  @override
  List<Object?> get props => [
    sendFailing,
    unicastUnconfirmed,
    rtt,
    staleEpochDrops,
    duplicateRouteDrops,
    blockedSends,
    peerCount,
  ];
}
