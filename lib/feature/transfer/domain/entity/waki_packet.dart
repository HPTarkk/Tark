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

  const PresencePacket({
    required super.senderId,
    required super.senderName,
    required this.isTalking,
    this.role = SessionRole.unknown,
  });

  @override
  List<Object?> get props => [...super.props, isTalking, role];
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
