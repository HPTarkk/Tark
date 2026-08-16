import 'package:equatable/equatable.dart';

/// Transport-level messages that never reach the session.
///
/// Deliberately a separate hierarchy from [WakiPacket] rather than two more
/// cases on it. A ping is not something the channel has an opinion about — it
/// carries no voice, no roster change and no talking state — and adding it to
/// the sealed type the cubit switches over would push a transport concern into
/// every consumer, including Bluetooth and the guest link, which do not need
/// one. The transport answers these itself and yields nothing.
sealed class ControlPacket extends Equatable {
  const ControlPacket({
    required this.senderId,
    required this.sessionEpoch,
    required this.token,
    required this.lastTxSeq,
    required this.lastRxSeq,
    required this.audioRxPackets,
  });

  final String senderId;

  /// Which of the sender's joins this belongs to — same meaning as on
  /// [WakiPacket], and the same reason: a pong from a previous session must
  /// not confirm this one.
  final int sessionEpoch;

  /// Echoed unchanged by the responder, so a pong can be matched to the ping
  /// that caused it. Matching matters for more than tidiness: without it, a
  /// late pong from an earlier ping would be timed against the most recent one
  /// and report an RTT far shorter than the truth.
  final int token;

  /// The highest audio sequence the sender has *sent*. Compared against the
  /// receiver's [lastRxSeq] for that peer, this is a direct loss measurement
  /// that neither end could make alone.
  final int lastTxSeq;

  /// The highest audio sequence the sender has *received* from the peer it is
  /// addressing.
  final int lastRxSeq;

  /// How many audio packets the sender has received from that peer.
  final int audioRxPackets;

  @override
  List<Object?> get props => [
    senderId,
    sessionEpoch,
    token,
    lastTxSeq,
    lastRxSeq,
    audioRxPackets,
  ];
}

/// "Are you there, on this exact path?" — sent unicast only.
final class PingPacket extends ControlPacket {
  const PingPacket({
    required super.senderId,
    required super.sessionEpoch,
    required super.token,
    super.lastTxSeq = 0,
    super.lastRxSeq = 0,
    super.audioRxPackets = 0,
  });
}

/// The answer, echoing [ControlPacket.token].
final class PongPacket extends ControlPacket {
  const PongPacket({
    required super.senderId,
    required super.sessionEpoch,
    required super.token,
    super.lastTxSeq = 0,
    super.lastRxSeq = 0,
    super.audioRxPackets = 0,
  });
}
