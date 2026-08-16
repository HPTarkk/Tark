import 'package:equatable/equatable.dart';

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

  const WakiPacket({
    required this.senderId,
    required this.senderName,
    this.sessionEpoch = kUnknownSessionEpoch,
  });

  /// Whether this packet says anything about which join it came from.
  bool get hasSessionEpoch => sessionEpoch != kUnknownSessionEpoch;

  @override
  List<Object?> get props => [senderId, senderName, sessionEpoch];
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

  const PresencePacket({
    required super.senderId,
    required super.senderName,
    required this.isTalking,
    super.sessionEpoch,
    this.role = SessionRole.unknown,
    this.heardIds,
  });

  @override
  List<Object?> get props => [...super.props, isTalking, role, heardIds];
}

final class AudioPacket extends WakiPacket {
  final List<double> samples;

  /// Monotonically increasing per-sender counter used by the jitter buffer
  /// to detect lost/out-of-order UDP packets and conceal the gaps.
  final int seq;

  const AudioPacket({
    required super.senderId,
    required super.senderName,
    required this.samples,
    required this.seq,
    super.sessionEpoch,
  });

  @override
  List<Object?> get props => [...super.props, samples, seq];
}
