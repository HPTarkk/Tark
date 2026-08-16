/// What [SessionEpochGate.offer] decided about one arriving packet.
enum EpochDecision {
  /// First packet from this sender — whatever epoch it carries is now the one
  /// we listen to.
  adopted,

  /// The epoch we are already listening to. Ordinary traffic.
  accepted,

  /// A higher epoch than the one held: the sender left and rejoined, and this
  /// is the new session taking over.
  renewed,

  /// A *lower* epoch than the one held — a packet from a join that has already
  /// ended, arriving late. Drop it.
  stale,
}

/// The outcome of offering a packet, with what the caller needs to log.
class EpochVerdict {
  const EpochVerdict(this.decision, {this.previous, this.offered});

  final EpochDecision decision;

  /// The epoch that was being listened to before this packet, on
  /// [EpochDecision.renewed] and [EpochDecision.stale].
  final int? previous;

  /// The epoch the packet actually carried, on the same two decisions.
  final int? offered;

  bool get isAccepted => decision != EpochDecision.stale;
}

/// Drops packets belonging to a sender's *previous* join of the channel.
///
/// ## Why this exists
///
/// A device that leaves a channel and rejoins keeps its [DeviceIdentity] — it
/// is the same process, and identity is per process. Everything downstream
/// therefore treats the new join as a continuation of the old one, including
/// the jitter buffer, which tracks one sequence counter per sender.
///
/// That is fine until a datagram from before the rejoin turns up after it.
/// UDP has no connection to tear down, so anything already queued in a driver,
/// a SoftAP's buffer, or a retransmitting Bluetooth stack is still in flight
/// and still addressed correctly. It arrives carrying the old join's sequence
/// number, the buffer sees its stream jump backwards by however far that
/// counter had climbed, and resyncs — a flush the user hears as speech
/// repeating or breaking up. The window is not small: hotspot restarts and
/// network handoffs are exactly when packets sit longest in queues, and a
/// measured session saw copies arrive 6.3 seconds apart.
///
/// [SenderRoutePin] solves the neighbouring problem — one device arriving on
/// two paths at once — and cannot help here. Both copies are on the pinned
/// route and both are genuinely from that sender; the difference is *when*
/// they were sent, which only an epoch can express.
///
/// ## Why a counter and not a timestamp
///
/// Epochs are only ever compared against another epoch from the *same* device.
/// The question is "is this packet from an older join than the one I am
/// listening to", never "did this device join before that one". So no clock is
/// needed and no clocks have to agree — a monotonic counter is a total order
/// over exactly the set that matters, and two devices are free to be sitting
/// on the same epoch number.
///
/// ## Why a higher epoch takes over immediately
///
/// A rejoin must be audible at once. Making the new session wait out a grace
/// period — the way a route repin does — would trade a broken-audio bug for
/// several seconds of silence every time someone reconnects, which is the
/// common case on a motorcycle. The ordering makes the grace unnecessary:
/// a higher epoch is unambiguously the newer session, so there is nothing to
/// disambiguate by waiting.
///
/// Pure bookkeeping — the caller does the logging — so this is testable
/// without a socket.
class SessionEpochGate {
  final Map<String, int> _current = {};

  /// Offers a packet from [senderId] stamped with [epoch].
  EpochVerdict offer(String senderId, int epoch) {
    final held = _current[senderId];

    if (held == null) {
      _current[senderId] = epoch;
      return const EpochVerdict(EpochDecision.adopted);
    }

    if (held == epoch) return const EpochVerdict(EpochDecision.accepted);

    if (epoch > held) {
      _current[senderId] = epoch;
      return EpochVerdict(
        EpochDecision.renewed,
        previous: held,
        offered: epoch,
      );
    }

    return EpochVerdict(EpochDecision.stale, previous: held, offered: epoch);
  }

  /// The epoch [senderId] is currently accepted on, if any.
  int? epochFor(String senderId) => _current[senderId];

  /// Forgets a sender entirely — it left, or the session did.
  void forget(String senderId) => _current.remove(senderId);

  void clear() => _current.clear();
}
