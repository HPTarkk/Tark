/// What [ChannelHealthMonitor.audibility] concluded on one roster tick.
enum AudibilityVerdict {
  /// Nothing to grade (empty channel, not ready): any warning goes.
  clear,

  /// Not enough evidence either way yet: leave the flag as it is.
  unchanged,

  /// Peers we can hear have stopped listing us for long enough: warn, and
  /// ask the transport to repair its send path.
  unheard,
}

/// The "has this been wrong for a while now?" questions the channel asks on
/// its roster tick: is the mic delivering, does this phone have an address,
/// can anybody hear us, is anybody here.
///
/// Pure bookkeeping over timestamps. Callers pass `now` and act on the
/// answers (emit, cue, log); nothing here has side effects, so each grace
/// period is testable without a clock.
///
/// Every answer is null or [AudibilityVerdict.unchanged] when the monitor has
/// no opinion, so a caller only ever changes a flag on real evidence.
class ChannelHealthMonitor {
  ChannelHealthMonitor({
    this.unheardAfter = const Duration(seconds: 7),
    this.micSilentAfter = const Duration(seconds: 6),
    this.noAddressGrace = const Duration(seconds: 5),
    this.aloneAfter = const Duration(seconds: 20),
  });

  /// How long peers must consistently report not hearing us before it counts.
  /// Several presence ticks (they arrive every 2s), so this needs a sustained
  /// disagreement rather than one lost datagram.
  final Duration unheardAfter;

  /// Silence longer than this, with the engine claiming to be started, means
  /// the mic is not actually feeding us. Generous: a slow device can take a
  /// couple of seconds to deliver its first callback.
  final Duration micSilentAfter;

  /// How long a missing local address must persist before it's reported.
  final Duration noAddressGrace;

  /// How long to sit in an empty channel before saying so. Long enough that
  /// a peer joining normally is never preceded by a "you're alone" card.
  final Duration aloneAfter;

  /// When the channel finished opening, for the "nobody else is here" check —
  /// which is only worth saying once enough time has passed for someone to
  /// have shown up. Also the session's start for analytics.
  DateTime? get readyAt => _readyAt;
  DateTime? _readyAt;

  /// Last mic frame that actually arrived. The engine can report itself
  /// started and then deliver nothing at all (see [micDelivering]), so
  /// "started" is not evidence the mic works — a frame is.
  DateTime? _lastFrameAt;

  /// When this device first had no usable local address, so a momentary gap
  /// during a network change isn't announced as a failure.
  DateTime? _noAddressSince;

  /// Last time a peer's presence packet listed *us* among the devices it can
  /// hear — proof our transmissions are arriving somewhere.
  ///
  /// Everything else the channel grades is about receiving. A phone whose
  /// outgoing path has died still has a bound socket, a healthy link, a
  /// populated roster and a working mic, and every check on the
  /// troubleshooting sheet goes green while nobody can hear it. This is the
  /// only local evidence to the contrary there is.
  DateTime? _lastHeardByPeerAt;

  /// When peers started reporting they can't hear us, so a single dropped
  /// presence packet isn't treated as going mute.
  DateTime? _unheardSince;

  /// Forgets everything, for a retry that starts from a fresh session.
  void reset() {
    _readyAt = null;
    _lastFrameAt = null;
    _noAddressSince = null;
    _lastHeardByPeerAt = null;
    _unheardSince = null;
  }

  /// The channel is open. Both clocks start here rather than at construction:
  /// everything before this is legitimate warm-up, and grading the mic or the
  /// roster against it would report a failure for a channel merely opening.
  void markReady(DateTime now) {
    _readyAt = now;
    _lastFrameAt = now;
  }

  /// A mic frame arrived (or the mic was just restarted and deserves a fresh
  /// grace period).
  void noteFrame(DateTime now) => _lastFrameAt = now;

  /// A peer listed us as heard.
  void noteHeardByPeer(DateTime now) {
    _lastHeardByPeerAt = now;
    _unheardSince = null;
  }

  /// Starts the "can't hear us" stretch over from [now]: after a resume
  /// (whatever peers said while the phone was locked is not evidence about
  /// the link now) or a manual repair (which deserves a full grace period to
  /// prove itself). Moved forward rather than cleared — clearing would let the
  /// check fall back to the last confirmation, the very timestamp on the far
  /// side of the gap being discounted.
  void restartUnheardClock(DateTime now) => _unheardSince = now;

  /// Whether mic frames are arriving, or null while there is nothing to grade
  /// (not ready, no permission, no frame clock yet).
  bool? micDelivering({
    required DateTime now,
    required bool isReady,
    required bool hasPermission,
  }) {
    if (!isReady || !hasPermission) return null;
    final last = _lastFrameAt;
    if (last == null) return null;
    return now.difference(last) < micSilentAfter;
  }

  /// Whether a missing address has lasted long enough to report, or null
  /// while it is inside the grace period (leave the flag as it is).
  bool? networkMissing({
    required DateTime now,
    required bool needsAddress,
    required bool isReady,
    required String localId,
  }) {
    final missing =
        needsAddress && isReady && (localId.isEmpty || localId == '0.0.0.0');
    if (!missing) {
      _noAddressSince = null;
      return false;
    }
    // A network change legitimately drops the address for a moment — only a
    // gap that outlasts the grace is worth a card.
    final since = _noAddressSince ??= now;
    if (now.difference(since) < noAddressGrace) return null;
    return true;
  }

  /// Whether the people we can hear can hear us.
  ///
  /// Graded only while there is somebody in the roster whose presence carries
  /// an opinion. An empty channel says nothing about audibility.
  AudibilityVerdict audibility({
    required DateTime now,
    required bool isReady,
    required bool hasPeers,
  }) {
    if (!isReady || !hasPeers) {
      // The confirmation clock goes with an empty channel: a peer arriving
      // after a long gap has not had a chance to hear us yet, and grading it
      // against the last person who did would flash a warning at every join.
      _unheardSince = null;
      _lastHeardByPeerAt = null;
      return AudibilityVerdict.clear;
    }
    // Never heard back at all yet: this is a channel still forming, not a
    // broken one. Only once some peer has confirmed us is its absence
    // evidence of anything.
    final confirmed = _lastHeardByPeerAt;
    if (confirmed == null) return AudibilityVerdict.unchanged;
    final since = _unheardSince ??= confirmed;
    return now.difference(since) < unheardAfter
        ? AudibilityVerdict.unchanged
        : AudibilityVerdict.unheard;
  }

  /// Whether the channel has been open a while with nobody else in it, or
  /// null before it has opened.
  bool? alone({required DateTime now, required bool hasPeers}) {
    final readyAt = _readyAt;
    if (readyAt == null) return null;
    return !hasPeers && now.difference(readyAt) >= aloneAfter;
  }
}
