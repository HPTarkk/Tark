import '../entity/media_receiver_feedback.dart';

/// Session-scoped store for the latest Shared Music receiver feedback by peer.
///
/// Feedback is intentionally ephemeral: it is transport/session evidence, not
/// durable Room membership. Missing or stale evidence is returned as `null` so
/// the sender adaptation policy remains conservative instead of accidentally
/// treating an old clean sample as current health.
class MediaReceiverFeedbackStore {
  MediaReceiverFeedbackStore({
    this.staleAfter = const Duration(seconds: 8),
  }) : assert(!staleAfter.isNegative);

  final Duration staleAfter;
  final Map<String, _PeerFeedback> _byPeer = {};

  /// Records one decoded feedback window for [peerId]. Empty ids are ignored;
  /// transport addresses/identifiers remain session-local and are never
  /// persisted by this store.
  void observe(
    String peerId,
    MediaReceiverFeedback feedback,
    DateTime now,
  ) {
    if (peerId.isEmpty) return;
    _byPeer[peerId] = _PeerFeedback(feedback: feedback, observedAt: now);
  }

  /// Returns one slot for every currently relevant peer, preserving `null` for
  /// peers that have never reported feedback or whose evidence is stale.
  ///
  /// Keeping the slot is important: filtering missing peers would let a
  /// mixed-version room look healthier than it is and could promote media to
  /// a tier unsupported by the silent receiver.
  List<MediaReceiverFeedback?> snapshot(
    Iterable<String> peerIds,
    DateTime now,
  ) {
    return peerIds.map((peerId) {
      final entry = _byPeer[peerId];
      if (entry == null) return null;
      if (now.difference(entry.observedAt) > staleAfter) return null;
      return entry.feedback;
    }).toList(growable: false);
  }

  void removePeer(String peerId) {
    _byPeer.remove(peerId);
  }

  /// Called when a transport attachment/session generation is replaced. Old
  /// receiver health must never survive into the new path.
  void reset() {
    _byPeer.clear();
  }
}

class _PeerFeedback {
  const _PeerFeedback({required this.feedback, required this.observedAt});

  final MediaReceiverFeedback feedback;
  final DateTime observedAt;
}
