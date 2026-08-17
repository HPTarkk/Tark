/// Measures how much of *our* audio each peer is failing to receive.
///
/// ## Why this is the only honest source
///
/// Loss in the direction our voice travels cannot be measured at this end. We
/// can count what we sent; only the far end can count what arrived. Every local
/// statistic — packets received, sockets bound, peers in the roster — describes
/// the *other* direction, and tuning our encoder from those would have each
/// phone react to its peer's problem instead of its own.
///
/// The measurement was already on the wire before anything read it. P0's
/// unicast ping/pong carries `audioRxPackets` — "how many audio packets I have
/// received from you" — and `ControlPacket` has said since it was written that
/// comparing it against the sender's own count is "a direct loss measurement
/// that neither end could make alone". Until now the pong's counters were sent,
/// answered, and thrown away; only the token was used, for RTT. This is the
/// consumer they were put there for.
///
/// ## Counts, not sequence numbers
///
/// Both ends already exchange `lastTxSeq`/`lastRxSeq`, which look like the
/// natural inputs. They are not: a sequence counter lives on the transport
/// repository and restarts at zero whenever the transport is rebuilt, while the
/// device identity keying this map does not restart with it — so a rejoin makes
/// a sequence difference meaningless in a way a monotonic count of delivered
/// packets is not. The counts also need no agreement about where numbering
/// started.
///
/// Pure bookkeeping — the caller owns the clock and the socket — so this is
/// testable without either.
class PeerLossTracker {
  PeerLossTracker({this.minimumSamplePackets = 25, this.smoothing = 0.4})
    : assert(minimumSamplePackets > 0),
      assert(smoothing > 0 && smoothing <= 1);

  /// How much audio must have been sent since the last sample before a loss
  /// figure is computed from it.
  ///
  /// Twenty-five packets is half a second of continuous speech. Below that the
  /// arithmetic is dominated by the handful of packets still in flight when the
  /// peer answered, and — more to the point — a channel where nobody is talking
  /// sends no audio at all, so every window would divide by something close to
  /// zero and report wild loss for a link doing nothing wrong.
  final int minimumSamplePackets;

  /// Weight given to the newest window in the running estimate (0–1].
  ///
  /// Loss on a hotspot arrives in bursts — a phone passing a truck can drop a
  /// tenth of a second wholesale — and retuning the encoder to 25 % redundancy
  /// for one such burst, then back, is worse than either setting. At 0.4 a
  /// single bad window moves the estimate most of the way but not all, and two
  /// consecutive ones commit.
  final double smoothing;

  final Map<String, _PeerLoss> _byPeer = {};

  /// Records the counters from a peer's pong and returns the updated estimate
  /// for it, or null while there is not yet enough traffic to judge.
  ///
  /// [ourSentCount] is how many audio packets we have sent, and
  /// [theirReceivedCount] how many that peer says it has received from us.
  double? sample(
    String peerId, {
    required int ourSentCount,
    required int theirReceivedCount,
  }) {
    final peer = _byPeer.putIfAbsent(
      peerId,
      () => _PeerLoss(ourSentCount, theirReceivedCount),
    );

    final sent = ourSentCount - peer.sentAtLastSample;
    final received = theirReceivedCount - peer.receivedAtLastSample;

    // Either counter going backwards means a restart — the peer rejoined, or
    // our transport was rebuilt — so the two baselines no longer describe the
    // same stream. Rebase and wait for the next window rather than reporting
    // the enormous fake loss the subtraction would otherwise produce.
    if (sent < 0 || received < 0) {
      peer.rebase(ourSentCount, theirReceivedCount);
      return peer.estimate;
    }

    if (sent < minimumSamplePackets) return peer.estimate;

    // Clamped at zero because the two counts are sampled a round trip apart:
    // a peer can legitimately report having received packets we had not yet
    // counted as sent when the previous window closed, which is skew, not
    // negative loss.
    final windowLoss = ((sent - received) / sent).clamp(0.0, 1.0);
    peer.observe(windowLoss, smoothing);
    peer.rebase(ourSentCount, theirReceivedCount);
    return peer.estimate;
  }

  /// The current estimate for [peerId], or null if it has never produced one.
  double? lossFor(String peerId) => _byPeer[peerId]?.estimate;

  /// The worst estimate across every peer, or 0 when nothing has been measured.
  ///
  /// Worst rather than average, for the same reason [LinkQualityGrader] grades
  /// that way — and here it is forced as well as principled: one encoded packet
  /// goes to every peer, so the stream has to survive the worst link it is
  /// addressed to. Averaging would let two good peers vote a third into
  /// unintelligibility.
  double get worstLossFraction {
    var worst = 0.0;
    for (final peer in _byPeer.values) {
      final estimate = peer.estimate;
      if (estimate != null && estimate > worst) worst = estimate;
    }
    return worst;
  }

  /// Which peer is currently worst, for the session log — "13 % loss" is a
  /// different problem from "13 % loss, always the same phone".
  String? get worstPeerId {
    String? worstId;
    var worst = 0.0;
    for (final entry in _byPeer.entries) {
      final estimate = entry.value.estimate;
      if (estimate != null && estimate > worst) {
        worst = estimate;
        worstId = entry.key;
      }
    }
    return worstId;
  }

  /// Forgets a peer entirely — it left, or the session did.
  void forget(String peerId) => _byPeer.remove(peerId);

  /// Drops every peer not in [livePeerIds].
  ///
  /// Must be called as the roster ages, and the reason is [worstLossFraction]:
  /// a rider who drops off the back of the group at 40 % loss, or simply ends
  /// the call, would otherwise keep that estimate in the map for the rest of
  /// the session — and being the worst, it would hold the encoder at its lowest
  /// bitrate and highest redundancy for everyone still talking. The measurement
  /// has to expire with the peer it describes.
  void retain(Iterable<String> livePeerIds) {
    final live = livePeerIds.toSet();
    _byPeer.removeWhere((peerId, _) => !live.contains(peerId));
  }

  void clear() => _byPeer.clear();
}

class _PeerLoss {
  _PeerLoss(this.sentAtLastSample, this.receivedAtLastSample);

  int sentAtLastSample;
  int receivedAtLastSample;

  /// Null until a full window has been measured. Deliberately not zero: "no
  /// loss observed" and "not measured yet" lead to the same encoder settings
  /// today, but only one of them is a claim about the link.
  double? estimate;

  void observe(double windowLoss, double smoothing) {
    final previous = estimate;
    estimate = previous == null
        ? windowLoss
        : previous + smoothing * (windowLoss - previous);
  }

  void rebase(int sent, int received) {
    sentAtLastSample = sent;
    receivedAtLastSample = received;
  }
}
