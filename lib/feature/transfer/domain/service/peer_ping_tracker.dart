/// Tracks whether each peer answers on the **unicast** path, and how fast.
///
/// ## Why this exists
///
/// Presence and audio do not travel the same way. Presence always takes the
/// broadcast leg *and* the unicast leg; audio, once peers are known, takes
/// unicast only (see `needsBroadcastLeg`). So presence arriving proves the
/// broadcast path works, which is not the path carrying voice.
///
/// That gap is not theoretical. `heardIds` — the mechanism for "can anybody
/// hear me?" — rides on presence and is set by *any* decoded packet, so a peer
/// reachable by broadcast but not unicast still reports hearing us. Every
/// local signal then says the link is healthy while our audio reaches that
/// peer and no other, and the phone shows a full-strength meter.
///
/// Total unicast failure is already caught elsewhere: the send-path grader
/// notices when *every* target fails and falls back to broadcasting audio.
/// What it cannot see is a **partial** failure — it treats `failed < attempted`
/// as healthy — so one unreachable peer among several stays unreachable
/// indefinitely. That needs three or more participants to happen at all, which
/// is why two-phone field tests never surfaced it.
///
/// A ping sent unicast and answered unicast is the only evidence that the path
/// audio actually uses is open, end to end, right now.
///
/// Pure bookkeeping — the caller owns the clock and the socket — so this is
/// testable without either.
class PeerPingTracker {
  PeerPingTracker({this.grace = const Duration(seconds: 6)});

  /// How long a peer may go without answering before its unicast path is
  /// treated as broken.
  ///
  /// Six seconds at the one-second ping cadence means six unanswered pings.
  /// Deliberately the same as the route pin's grace: both are answering "has
  /// this path stopped working, or did we just lose a couple of datagrams",
  /// and a single dropped ping must never be enough to reroute a session.
  final Duration grace;

  final Map<String, DateTime> _firstPingAt = {};
  final Map<String, DateTime> _lastPongAt = {};
  final Map<String, Duration> _rtt = {};

  /// In-flight pings by address, so a pong can be timed against the ping that
  /// actually caused it.
  final Map<String, Map<int, DateTime>> _pending = {};

  /// Ceiling on in-flight pings per peer. A peer that never answers would
  /// otherwise accumulate one entry per second for the life of the session.
  static const _maxPending = 16;

  /// Records a ping going out to [address].
  void sent(String address, int token, DateTime at) {
    _firstPingAt.putIfAbsent(address, () => at);
    final pending = _pending.putIfAbsent(address, () => {});
    if (pending.length >= _maxPending) {
      // Oldest first: if it has not been answered by now it never will be.
      pending.remove(pending.keys.first);
    }
    pending[token] = at;
  }

  /// Records a pong from [address]. Returns the round-trip time when the token
  /// matches a ping we actually sent, and null otherwise.
  ///
  /// An unmatched token still counts as confirmation — the peer plainly
  /// answered *something* — but yields no RTT, because timing it against the
  /// wrong ping is worse than not timing it at all.
  Duration? pong(String address, int token, DateTime at) {
    _lastPongAt[address] = at;
    final sentAt = _pending[address]?.remove(token);
    if (sentAt == null) return null;
    final rtt = at.difference(sentAt);
    _rtt[address] = rtt;
    return rtt;
  }

  /// Last measured round trip to [address].
  Duration? rttFor(String address) => _rtt[address];

  /// When [address] last answered.
  DateTime? confirmedAt(String address) => _lastPongAt[address];

  /// Whether [address] has stopped answering on the unicast path.
  ///
  /// False for an address never pinged, and false while the first ping is
  /// still inside the grace — a peer that has just been discovered has not had
  /// a chance to answer, and grading it would declare every new arrival broken
  /// for its first few seconds.
  bool isUnconfirmed(String address, DateTime now) {
    final firstPing = _firstPingAt[address];
    if (firstPing == null) return false;
    final lastPong = _lastPongAt[address];
    if (lastPong == null) return now.difference(firstPing) > grace;
    return now.difference(lastPong) > grace;
  }

  /// Which of [addresses] have stopped answering.
  List<String> unconfirmedAmong(Iterable<String> addresses, DateTime now) => [
    for (final address in addresses)
      if (isUnconfirmed(address, now)) address,
  ];

  /// Forgets an address entirely — it left, or the session did.
  void forget(String address) {
    _firstPingAt.remove(address);
    _lastPongAt.remove(address);
    _rtt.remove(address);
    _pending.remove(address);
  }

  void clear() {
    _firstPingAt.clear();
    _lastPongAt.clear();
    _rtt.clear();
    _pending.clear();
  }
}
