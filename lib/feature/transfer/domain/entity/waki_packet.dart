import 'package:equatable/equatable.dart';

import 'session_role.dart';

sealed class WakiPacket extends Equatable {
  final String senderId;
  final String senderName;

  const WakiPacket({required this.senderId, required this.senderName});

  @override
  List<Object?> get props => [senderId, senderName];
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
  });

  @override
  List<Object?> get props => [...super.props, samples, seq];
}
