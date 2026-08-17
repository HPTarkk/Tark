/// Decides when a packet can be used to rebuild the one before it.
///
/// Opus in-band FEC carries a redundant copy of the **immediately** preceding
/// frame and nothing further back, so recovery is possible in exactly one
/// situation: a single packet is missing, and the packet after it has arrived.
/// This holds the per-sender sequence state that decision needs.
///
/// ## Why the rule is a class and not an `if`
///
/// The test is one comparison; the bookkeeping around it is where the bug
/// lives. A FEC decode advances the native decoder by a frame, so attempting
/// one that is not warranted does not merely waste work — it desynchronises the
/// decoder against the stream, and every packet after it decodes from the wrong
/// state.
///
/// The case that gets this wrong is ordinary UDP reordering. Given 10, 12, 11,
/// 13: packet 12 correctly recovers 11, then the real 11 arrives late. If the
/// late packet is allowed to rewind the sequence, 13 then looks like a
/// one-packet gap after 11 and "recovers" 12 — a frame already played, decoded
/// a second time, out of order. So [observe] advances only forwards, and a
/// straggler is recorded as heard without moving anything.
///
/// Pure — no clock, no codec — so the ordering rules can be tested directly.
class FecGapTracker {
  final Map<String, int> _lastSeqBySender = {};

  /// Records that [seq] arrived from [senderId] and reports whether the packet
  /// should be used to reconstruct `seq - 1`.
  ///
  /// True only when exactly one packet is missing. False for a first packet
  /// (there is no decoder state to rebuild from), an unbroken sequence (nothing
  /// to rebuild), a gap of two or more (genuinely gone — see the class comment),
  /// and anything at or behind what has already been decoded.
  bool observe(String senderId, int seq) {
    final lastSeq = _lastSeqBySender[senderId];
    if (lastSeq == null) {
      _lastSeqBySender[senderId] = seq;
      return false;
    }
    // A straggler or a duplicate. Heard, but it must not move the sequence —
    // that is what would manufacture a false gap out of the next packet.
    if (seq <= lastSeq) return false;

    _lastSeqBySender[senderId] = seq;
    return seq == lastSeq + 2;
  }

  /// Forgets a sender's sequence state.
  ///
  /// Must be called whenever that sender's decoder is discarded. A sequence
  /// remembered across a decoder reset would make the first packet after it
  /// look like a one-packet gap, and hand a recovery attempt to a decoder with
  /// no state to build it from.
  void forget(String senderId) => _lastSeqBySender.remove(senderId);

  void clear() => _lastSeqBySender.clear();
}
