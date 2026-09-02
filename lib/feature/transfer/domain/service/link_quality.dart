import '../entity/connection_health.dart';

/// How well the link is actually carrying voice, as one word.
///
/// Ordered best to worst; [LinkQuality.recovering] is the floor rather than a
/// separate axis, because from the user's seat "the app is fixing it" and "the
/// link is bad" are the same instruction: wait, or stop and sort it out.
enum LinkQuality {
  excellent,
  good,
  weak,
  recovering,

  /// The channel is up and there is nobody else on it.
  ///
  /// Its own rung rather than a grade, because it is not a measurement of a
  /// link — there is no link to measure. It used to be graded `good`, on the
  /// reasoning that an empty channel is not *broken*; the effect was that two
  /// phones which had failed to find each other both sat there showing LIVE
  /// and three green bars, each transmitting into nothing, with the interface
  /// agreeing that everything was fine. That is the single most expensive
  /// thing this indicator can get wrong: it is the state people check
  /// precisely to find out whether the silence they are hearing is them or the
  /// network, and answering "good" sends them looking at their headset.
  alone,
}

/// The evidence a grade is made from. All of it is already measured somewhere
/// in the transport or the session — this is the shape it arrives in.
class LinkSignals {
  const LinkSignals({
    required this.health,
    this.sendFailing = false,
    this.unheardByPeers = false,
    this.unicastUnconfirmed = false,
    this.rtt,
    this.staleEpochDrops = 0,
    this.duplicateRouteDrops = 0,
    this.blockedSends = 0,
    this.hasPeers = true,
  });

  /// Which rung of the recovery ladder the transport is on.
  final ConnectionHealth health;

  /// Every unicast target has been failing for longer than the grace — the
  /// send socket is bound to a network that is gone.
  final bool sendFailing;

  /// A peer we can hear says it cannot hear us. See `PresencePacket.heardIds`.
  final bool unheardByPeers;

  /// A peer we can hear has stopped answering unicast pings, so our audio is
  /// not reaching it — see `PeerPingTracker`.
  ///
  /// Distinct from [unheardByPeers] and strictly stronger. That flag is the
  /// peer's own report, and it arrives on presence, which reaches it over
  /// broadcast; a peer unreachable by unicast will happily keep confirming
  /// that it hears us while none of our audio lands. This is the signal that
  /// catches what that one cannot.
  final bool unicastUnconfirmed;

  /// Packets dropped in the last window as belonging to a sender's previous
  /// join. See `SessionEpochGate`.
  final int staleEpochDrops;

  /// Packets dropped in the last window as a second copy arriving by another
  /// route. See `SenderRoutePin`.
  final int duplicateRouteDrops;

  /// Datagrams the socket refused to queue in the last window — on a SoftAP
  /// this is the number that moves when a client is at the edge of range.
  final int blockedSends;

  /// Last measured round trip, when a pong has been matched. Null means
  /// unmeasured, which is not the same as slow and is never graded as such.
  final Duration? rtt;

  /// Whether anyone is in the channel at all. A solo channel is not weak, it
  /// is empty, and grading it would put a warning on a link with nothing to
  /// carry.
  final bool hasPeers;
}

/// Turns [LinkSignals] into one of four words.
///
/// ## Why this is not a packet-loss percentage
///
/// The failures that actually ruin a ride do not show up as loss. A phone
/// whose send path has died receives perfectly and reports 0 % loss; a device
/// arriving on two routes at once delivers *more* packets than it should while
/// sounding terrible. Grading on loss alone would have called both of those
/// excellent — which is the same trap the troubleshooting sheet fell into when
/// every check it had was about receiving.
///
/// So the worst signal wins rather than an average: each input below is
/// sufficient on its own to make the link bad, and letting a healthy majority
/// outvote one broken thing is how a phone nobody can hear ends up showing
/// four green ticks.
///
/// Pure — no clock, no I/O — so the thresholds can be tested directly.
class LinkQualityGrader {
  const LinkQualityGrader();

  /// Dropped duplicates or ghosts per window past which the link is weak.
  ///
  /// Not zero. One straggler after a rejoin, or a single duplicate as a route
  /// is repinned, is the machinery working — exactly what those two classes
  /// were built to absorb — and flagging it would leave the indicator amber
  /// for every healthy reconnect.
  static const _dropTolerance = 5;

  /// Blocked sends per window past which the radio is judged to be struggling.
  /// A SoftAP queue backing up produces these in the thousands, so the
  /// threshold only has to be clear of ordinary bursts.
  static const _blockedTolerance = 20;

  /// Round trip past which the link is no longer excellent. Generous — this is
  /// a LAN, where a healthy hotspot answers in single-digit milliseconds, and
  /// 150 ms means the AP is queueing hard or the peer is at the edge of range.
  static const _rttTolerance = Duration(milliseconds: 150);

  LinkQuality grade(LinkSignals s) {
    // Anything the transport is actively repairing outranks every measurement
    // below, including the quiet rung: degraded says nothing to the *banner*,
    // but this indicator is the one place a quiet repair should still be
    // legible — it is what someone glances at to decide whether the silence
    // they are hearing is the channel or the network.
    if (!s.health.isLive ||
        s.health.status == ConnectionHealthStatus.degraded) {
      return LinkQuality.recovering;
    }

    // Our voice is going nowhere. The single most important state this can
    // report, and the only evidence for it comes from the far end.
    if (s.unheardByPeers || s.sendFailing || s.unicastUnconfirmed) {
      return LinkQuality.weak;
    }

    // Nobody to grade against, so nothing is graded. Reported as its own
    // state rather than folded into a grade: "alone" is a fact the user can
    // act on — go and check the other phone — and every grade on this scale
    // is a claim about a connection that does not exist.
    if (!s.hasPeers) return LinkQuality.alone;

    if (s.blockedSends > _blockedTolerance) return LinkQuality.weak;

    // A round trip this long is a link that still works and will sound bad:
    // the jitter buffer has to grow to cover it, and every exchange picks up
    // the delay. Only graded when actually measured — an unanswered ping is
    // already covered by unicastUnconfirmed above, and treating "no reading"
    // as "slow" would mark every channel weak for its first second.
    final rtt = s.rtt;
    if (rtt != null && rtt > _rttTolerance) return LinkQuality.good;
    if (s.staleEpochDrops > _dropTolerance ||
        s.duplicateRouteDrops > _dropTolerance) {
      return LinkQuality.good;
    }

    return LinkQuality.excellent;
  }
}
