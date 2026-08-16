/// Whether a packet about to go out needs the broadcast leg on top of the
/// unicasts to known peers.
///
/// ## Why this exists
///
/// The Wi-Fi transport sends everything twice by design: a directed broadcast
/// for the subnet, and a unicast to each peer it has heard from. That is right
/// for presence and wrong for audio, and until this existed there was nothing
/// in the code that could tell the two apart.
///
/// Presence needs the broadcast, and that is the whole reason the leg exists:
/// it is how a phone nobody has heard from yet learns the channel is here.
/// Discovery cannot be answered by unicast, because there is nothing to unicast
/// *to* until someone has been heard from.
///
/// Audio does not, once peers are known — and sending it anyway was doing real
/// damage. The repository narrows the broadcast to the /24 of each peer, so
/// after that narrowing the two legs carry the identical packet to the
/// identical phones over the identical interface. Both copies arrive. From a
/// field session on a hotspot (tark 1.0.15+16, two Android phones):
///
///     sender    out=+791   over 15s
///     receiver  in=+1595   over the same 15s      (2.02x)
///
/// and the receiver's playback buffer logged `late=` at exactly half of `pkts=`
/// in every single window — 758/1517, 749/1498, 750/1500. The second copy lands
/// with a sequence number already consumed and is thrown away by the reorder
/// branch in `AudioPlaybackBuffer.feed`. Both phones paid full airtime, SoftAP
/// queue and battery to deliver audio that was discarded on arrival, fifty
/// packets a second, for the length of the call.
///
/// `SenderRoutePin` cannot see this and should not be asked to: both copies
/// arrive from the same source address, so there is exactly one route and the
/// pin is right to say so (`dupRoute=0`, `routes={<id>:1}` throughout that
/// session). The duplication is on the send side, and this is where it ends.
///
/// ## Why unicast is the leg that stays
///
/// Not merely because it is the cheaper one. Every address the repository
/// unicasts to is one it has decoded a datagram from, whereas broadcast is the
/// leg that a SoftAP filters and that iOS drops outright without the multicast
/// entitlement. Keeping the leg that is known to have carried traffic is the
/// conservative choice, not the aggressive one.
///
/// Two ways back to broadcasting audio anyway, both meaning unicast cannot be
/// trusted to carry the session on its own:
///
///  * [hasLivePeers] false — the sender is falling back to its recovery set, or
///    has nothing at all, so where the audio should go is a guess;
///  * [unicastFailing] true — every unicast in the last window failed, and
///    until the send path grades healthy again the broadcast is the only leg
///    that might still be getting through.
bool needsBroadcastLeg({
  required bool isAudio,
  required bool hasLivePeers,
  required bool unicastFailing,
}) {
  if (!isAudio) return true;
  return !hasLivePeers || unicastFailing;
}
