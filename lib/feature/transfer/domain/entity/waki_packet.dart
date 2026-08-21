import 'package:equatable/equatable.dart';

import '../../../../core/identity/channel_id.dart';
import 'session_role.dart';

/// Epoch carried by a packet from a build that predates the field (wire v1 and
/// v2). Not a session anyone can reason about — it means "the sender expressed
/// no opinion" — so it is never compared against a real epoch and never used
/// to drop anything. [SessionEpoch] starts its counting at 1, so no build that
/// does stamp an epoch can ever emit this value.
const kUnknownSessionEpoch = 0;

sealed class WakiPacket extends Equatable {
  final String senderId;
  final String senderName;

  /// Which of the sender's joins this packet belongs to. See [SessionEpoch]
  /// for why it exists and [SessionEpochGate] for what reads it.
  final int sessionEpoch;

  /// Which conversation this packet belongs to, when more than one is sharing
  /// a network. See [ChannelId] for the value and [ChannelGate] for the admission
  /// rule.
  ///
  /// [ChannelId.open] for every build that predates wire v4 and for every session
  /// nobody named a channel in — which is most of them, and is why the gate has
  /// to treat open as permissive rather than as a channel of its own.
  final ChannelId channelId;

  const WakiPacket({
    required this.senderId,
    required this.senderName,
    this.sessionEpoch = kUnknownSessionEpoch,
    this.channelId = ChannelId.open,
  });

  /// Whether this packet says anything about which join it came from.
  bool get hasSessionEpoch => sessionEpoch != kUnknownSessionEpoch;

  @override
  List<Object?> get props => [senderId, senderName, sessionEpoch, channelId.value];
}

final class PresencePacket extends WakiPacket {
  final bool isTalking;

  /// The part the sender says it plays in the link. [SessionRole.unknown]
  /// when the sender is on a build that predates roles — presence carries it
  /// as a trailing byte those builds simply never wrote.
  final SessionRole role;

  /// Device ids the sender can currently hear.
  ///
  /// This is the only way a phone can find out that its own transmissions are
  /// going nowhere. Every other signal it has is about *receiving*: the socket
  /// is bound, packets are arriving, the roster has people in it, the mic is
  /// delivering frames — a device whose outgoing path is dead looks perfectly
  /// healthy by all of them, and reports itself as such. Hearing someone say
  /// "here is who I can hear" and not finding yourself on the list is the
  /// missing half.
  ///
  /// Null means the sender expressed no opinion — an older build (the ids ride
  /// as trailing bytes, which older decoders stop before), or a point-to-point
  /// transport with no peer set to report. An *empty* list is a statement: "I
  /// can hear nobody." Keeping the two apart is the whole point; treating a
  /// silent old build as "can't hear you" would have every mixed-version
  /// channel permanently repairing itself.
  final List<String>? heardIds;

  /// Which [AudioFormatProfile]s (`core/audio/`) beyond
  /// `AudioFormatProfile.legacy16k` the sender can negotiate to — bit
  /// `p.id - 2` for profile `p`. 0 from a build that predates this field (the
  /// trailing byte is simply absent) and from a build that hasn't advertised
  /// anything beyond legacy — both read the same way: legacy only. See
  /// [AudioCapabilityNegotiator].
  final int capabilityBitmask;

  const PresencePacket({
    required super.senderId,
    required super.senderName,
    required this.isTalking,
    super.sessionEpoch,
    super.channelId,
    this.role = SessionRole.unknown,
    this.heardIds,
    this.capabilityBitmask = 0,
  });

  @override
  List<Object?> get props => [
    ...super.props,
    isTalking,
    role,
    heardIds,
    capabilityBitmask,
  ];
}

final class AudioPacket extends WakiPacket {
  final List<double> samples;

  /// Monotonically increasing per-sender counter used by the jitter buffer
  /// to detect lost/out-of-order UDP packets and conceal the gaps.
  final int seq;

  /// The frame at `seq - 1`, rebuilt because that packet never arrived.
  ///
  /// Non-null only when exactly one packet was lost and the Opus decoder could
  /// reconstruct it — from the in-band FEC copy this packet carries for it, or
  /// failing that from libopus's own concealment. See [OpusDecodeResult].
  ///
  /// Consumers must play it **before** [samples], at sequence `seq - 1`. Doing
  /// so is what makes the recovery worth having: the jitter buffer then sees an
  /// unbroken run of sequence numbers and never conceals the gap with silence,
  /// which is what a lost packet used to sound like.
  final List<double>? recoveredSamples;

  const AudioPacket({
    required super.senderId,
    required super.senderName,
    required this.samples,
    required this.seq,
    super.sessionEpoch,
    super.channelId,
    this.recoveredSamples,
  });

  @override
  List<Object?> get props => [...super.props, samples, seq, recoveredSamples];
}

/// Shared Music, carried on its own sequence space — see #30. Byte-for-byte
/// the same shape as [AudioPacket] ([samples]/[seq]/[recoveredSamples]), and
/// deliberately not a variant of it: they travel as distinct wire types (see
/// `WakiPacketCodec`) so an old decoder that has never heard of an
/// independent media stream drops it outright rather than misreading it as
/// more voice, and so a corrupt/lost media packet can never disturb voice's
/// own sequence tracking, jitter buffer, or Opus decoder state.
final class MediaAudioPacket extends WakiPacket {
  final List<double> samples;

  /// Monotonically increasing per-sender counter, independent of
  /// [AudioPacket.seq] — voice and media are two separate streams with two
  /// separate sequence spaces, so one can drop or reorder packets without
  /// the other's jitter buffer ever finding out.
  final int seq;

  /// The frame at `seq - 1`, rebuilt the same way [AudioPacket.recoveredSamples]
  /// is — from this packet's in-band Opus FEC copy, or libopus's own
  /// concealment. See that field for the full contract.
  final List<double>? recoveredSamples;

  const MediaAudioPacket({
    required super.senderId,
    required super.senderName,
    required this.samples,
    required this.seq,
    super.sessionEpoch,
    super.channelId,
    this.recoveredSamples,
  });

  @override
  List<Object?> get props => [...super.props, samples, seq, recoveredSamples];
}
