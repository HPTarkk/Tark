/// What [SenderRoutePin.offer] decided about one arriving packet.
enum RouteDecision {
  /// First packet from this sender — the route it came in on is now its pin.
  pinned,

  /// Arrived on the pinned route. Ordinary traffic.
  accepted,

  /// Arrived on a different route after the pinned one went quiet past the
  /// grace, so this route takes over.
  repinned,

  /// Arrived on a different route while the pinned one is still delivering.
  /// A second copy of audio we are already receiving — drop it.
  rejected,
}

/// The outcome of offering a packet, with what the caller needs to react.
class RouteVerdict {
  const RouteVerdict(this.decision, {this.previous, this.previousSilence});

  final RouteDecision decision;

  /// The route that was abandoned, on [RouteDecision.repinned]. The caller
  /// uses this to stop unicasting to an address it no longer listens to.
  final String? previous;

  /// How long the abandoned route had been silent, for the log line.
  final Duration? previousSilence;

  bool get isAccepted => decision != RouteDecision.rejected;
}

/// Pins each sender to a single source address, so one device arriving by two
/// network paths is only ever heard once.
///
/// ## Why this exists
///
/// Phones running this app are routinely multi-homed. A device can host a
/// hotspot while still associated to a router, or — the case that produced
/// this class — two devices can each host a hotspot that the other has joined.
/// Every packet then arrives twice, on paths whose delay has nothing in common:
/// a measured session saw copies 6.3 seconds apart.
///
/// Nothing downstream can recover from that. The jitter buffer tracks one
/// sequence counter per SENDER, not per route, so two interleaved copies of one
/// stream read as a counter that keeps restarting. In that session it resynced
/// 2737 times, 331 times in the worst minute, and every resync is a buffer
/// flush the user hears as speech repeating or breaking up.
///
/// ## Why per sender rather than one subnet for the whole session
///
/// The defect is one phone arriving twice, not two phones on two networks. A
/// channel that legitimately spans a router and a hotspot keeps working here:
/// each participant is simply pinned to wherever it actually is. Pinning the
/// whole session to a single subnet would have solved the reported bug and
/// broken that arrangement for no reason.
///
/// ## Why the pin expires
///
/// A permanent pin would make a phone that genuinely moves networks mid-call
/// inaudible for the rest of the session — trading a bad-audio bug for a
/// no-audio one. So a pinned route that stops delivering for [grace] releases
/// its claim, and the next packet on any other route takes over.
///
/// [grace] is generous relative to the 2 s presence tick on purpose: it is the
/// only safety margin in this class, and five lost presence packets plus a
/// dropped talk burst must not be enough to hand the stream to a path that is
/// merely louder at that instant.
///
/// Pure bookkeeping — the caller owns the clock and does the logging, so this
/// can be tested without a socket.
class SenderRoutePin {
  SenderRoutePin({this.grace = const Duration(seconds: 6)});

  /// How long a pinned route may go quiet before another may take over.
  final Duration grace;

  final Map<String, String> _pinned = {};
  final Map<String, DateTime> _seenAt = {};

  /// Offers a packet from [senderId] that arrived at [address].
  RouteVerdict offer(String senderId, String address, DateTime now) {
    final pinned = _pinned[senderId];

    if (pinned == null) {
      _pinned[senderId] = address;
      _seenAt[senderId] = now;
      return const RouteVerdict(RouteDecision.pinned);
    }

    if (pinned == address) {
      _seenAt[senderId] = now;
      return const RouteVerdict(RouteDecision.accepted);
    }

    final lastSeen = _seenAt[senderId];
    // A missing timestamp cannot mean "the pin is fresh" — that would let a
    // pin with no evidence behind it block every other route forever. Treated
    // as expired, so the live route in hand wins.
    final silence = lastSeen == null ? null : now.difference(lastSeen);
    if (silence != null && silence < grace) {
      return const RouteVerdict(RouteDecision.rejected);
    }

    _pinned[senderId] = address;
    _seenAt[senderId] = now;
    return RouteVerdict(
      RouteDecision.repinned,
      previous: pinned,
      previousSilence: silence,
    );
  }

  /// The address [senderId] is currently accepted from, if any.
  String? pinnedFor(String senderId) => _pinned[senderId];

  /// Every currently pinned address, for diagnostics.
  List<String> get pinnedAddresses => _pinned.values.toList(growable: false);

  /// Forgets a sender entirely — it left, or the session did.
  void forget(String senderId) {
    _pinned.remove(senderId);
    _seenAt.remove(senderId);
  }

  void clear() {
    _pinned.clear();
    _seenAt.clear();
  }
}
