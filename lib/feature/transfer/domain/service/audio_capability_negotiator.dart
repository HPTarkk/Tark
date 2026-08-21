import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/service/fec_gap_tracker.dart';
import 'package:tark/feature/transfer/domain/service/peer_loss_tracker.dart';

import '../../../../core/audio/audio_format_profile.dart';

/// Resolves the highest [AudioFormatProfile] every currently-known peer has
/// advertised support for.
///
/// ## The advertisement
///
/// Each [PresencePacket] carries one capability bitmask — bit `p.id - 2` for
/// profile `p`, shared across every [AudioProfileKind] because ids are a
/// single space (see that field's doc) — see
/// [WakiPacketCodec.encodePresence]. [AudioFormatProfile.legacy16k] is never
/// encoded: an absent presence field (a build that predates this) and a zero
/// bitmask both mean the same thing, "legacy only," which is also the correct
/// safe default. That is what makes a mixed-version pair fall out of [resolve]
/// with no special-casing: an old peer's bitmask reads as 0, no bit it could
/// ever need is set, and the loop below settles on [AudioFormatProfile.legacy16k].
///
/// ## Voice vs media: one bitmask, two negotiators
///
/// A build constructs **two** instances of this class over the identical
/// bitmask stream: the default one (voice, ranked by
/// [AudioFormatProfile.supported]) and [AudioCapabilityNegotiator.media]
/// (ranked by [AudioFormatProfile.mediaSupported]). Every caller that already
/// tracks a peer's presence for voice feeds the same
/// `packet.capabilityBitmask` to both — see `observePeer`'s call sites in
/// each `TransferRepository`. Voice always has a safe floor to fall back to
/// ([AudioFormatProfile.legacy16k] — the channel has to carry speech
/// regardless), so [resolve] is what voice calls; media does not (there is no
/// "must always run" media profile — no mutual support just means no HD
/// media), so a media-kind instance calls [resolveOptional] instead, never
/// [resolve].
///
/// ## No acknowledgement round trip
///
/// Both ends of a link ship the identical ranked [AudioFormatProfile.supported]
/// list as app code, and presence already carries each side's advertisement.
/// So each side can independently compute "the highest profile every peer I
/// currently hear has confirmed" from information it already has — swap "my"
/// and "peer" and the intersection-then-highest-rank computation gives the
/// same answer, because it is commutative. Nothing here asks the far end to
/// agree; it already has, on its own copy of this same computation.
///
/// ## One negotiator, two shapes of peer set
///
/// A WiFi channel can hold more than one other participant, and the wire
/// carries one encoded stream for all of them — you cannot encode 24 kHz for
/// one peer and 16 kHz for another on a broadcast transport. So WiFi calls
/// [observePeer] for its whole heard roster and [retain] as it ages, while a
/// point-to-point transport (Bluetooth Classic, WebRTC guest) calls
/// [observePeer] for the one peer it has. [resolve] treats both the same way:
/// the answer is only as high as *every* currently-known peer supports.
///
/// Pure bookkeeping, no clock, no codec — same shape as [FecGapTracker] and
/// [PeerLossTracker] — so the negotiation algorithm is testable without a
/// socket, and a caller can hand this presence updates on whatever cadence
/// they arrive without thinking about it: [resolve] is cheap, and a caller
/// that only acts when its result *changes* gets "no packet-by-packet
/// flapping" for free, since presence ticks every couple of seconds rather
/// than at audio rate.
class AudioCapabilityNegotiator {
  /// [supported] defaults to the real, shipped [AudioFormatProfile.supported]
  /// (voice). Two legitimate reasons to override it: [media] below
  /// (production), and a test exercising the bit-matching logic against a
  /// profile independently of when a shipped list actually grows to include
  /// it.
  AudioCapabilityNegotiator({List<AudioFormatProfile>? supported})
    : _supported = supported ?? AudioFormatProfile.supported;

  /// A media-kind negotiator, ranked by [AudioFormatProfile.mediaSupported]
  /// instead of the voice list. Reads peer bitmasks exactly like a voice
  /// instance (same wire byte, different bits) — see the class doc — but
  /// must be resolved with [resolveOptional], never [resolve].
  factory AudioCapabilityNegotiator.media() =>
      AudioCapabilityNegotiator(supported: AudioFormatProfile.mediaSupported);

  final List<AudioFormatProfile> _supported;

  final Map<String, int> _bitmaskByPeer = {};

  /// The bits this build advertises about itself, derived from every real,
  /// shipped profile — voice ([AudioFormatProfile.supported]) and media
  /// ([AudioFormatProfile.mediaSupported]) together, since both ride the one
  /// wire byte (see the class doc) — the single source of truth for what
  /// this build claims to support, of either kind. Always the real lists,
  /// not an instance's overridden one: what a build advertises on the wire
  /// is a build-wide fact, not something a negotiator instance's test
  /// override should change — see [WakiPacketCodec.encodePresence], which
  /// has no negotiator instance to ask. [AudioFormatProfile.legacy16k] is
  /// skipped: it is never encoded (see the class doc).
  static int get localBitmask =>
      _bitmaskFor(AudioFormatProfile.supported) |
      _bitmaskFor(AudioFormatProfile.mediaSupported);

  static int _bitmaskFor(List<AudioFormatProfile> supported) {
    var mask = 0;
    for (final profile in supported) {
      if (profile == AudioFormatProfile.legacy16k) continue;
      mask |= 1 << (profile.id - 2);
    }
    return mask;
  }

  /// Records the capability bitmask [peerId]'s latest presence advertised.
  ///
  /// Idempotent to call on every presence tick, including an unchanged
  /// bitmask — [resolve] is what a caller diffs against, not this.
  void observePeer(String peerId, int bitmask) {
    _bitmaskByPeer[peerId] = bitmask;
  }

  /// Forgets one peer — it left, or its session did.
  void forget(String peerId) => _bitmaskByPeer.remove(peerId);

  /// Drops every peer not in [livePeerIds].
  ///
  /// Must be called as a WiFi roster ages, for the same reason
  /// [PeerLossTracker.retain] must: a peer who left but is still in this map
  /// would go on holding the negotiated profile down (or, once it can be
  /// negotiated up, holding an upgrade back) for everyone still in the
  /// channel.
  void retain(Iterable<String> livePeerIds) {
    final live = livePeerIds.toSet();
    _bitmaskByPeer.removeWhere((peerId, _) => !live.contains(peerId));
  }

  void clear() => _bitmaskByPeer.clear();

  /// The highest [AudioFormatProfile] every currently-known peer has
  /// advertised, ranked by [AudioFormatProfile.supported] (or this
  /// instance's override — see the constructor).
  ///
  /// [AudioFormatProfile.legacy16k] when no peer is known yet — negotiating
  /// up needs at least one peer to confirm it with, so an empty roster
  /// (nobody heard from, or everyone just left) resolves to the safe floor
  /// rather than vacuously to the top of the list.
  AudioFormatProfile resolve() {
    if (_bitmaskByPeer.isEmpty) return AudioFormatProfile.legacy16k;
    for (final profile in _supported) {
      if (profile == AudioFormatProfile.legacy16k) return profile;
      final bit = 1 << (profile.id - 2);
      final mutual = _bitmaskByPeer.values.every((mask) => mask & bit != 0);
      if (mutual) return profile;
    }
    return AudioFormatProfile.legacy16k;
  }

  /// [resolve]'s counterpart for a negotiator with no guaranteed-available
  /// floor in [_supported] — [media] instances, where "no currently-known
  /// peer supports any HD media profile" has to mean "don't attempt HD
  /// media," not silently fall back to a voice-shaped profile the way
  /// [resolve] falls back to [AudioFormatProfile.legacy16k]. Null covers
  /// both that case and an empty roster; a non-null result is ranked by
  /// [_supported] exactly like [resolve].
  AudioFormatProfile? resolveOptional() {
    for (final profile in _supported) {
      final bit = 1 << (profile.id - 2);
      final mutual =
          _bitmaskByPeer.isNotEmpty &&
          _bitmaskByPeer.values.every((mask) => mask & bit != 0);
      if (mutual) return profile;
    }
    return null;
  }
}
