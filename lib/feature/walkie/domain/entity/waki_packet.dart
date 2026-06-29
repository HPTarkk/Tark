import 'package:equatable/equatable.dart';

sealed class WakiPacket extends Equatable {
  final String senderIp;
  final String senderName;

  const WakiPacket({required this.senderIp, required this.senderName});

  @override
  List<Object?> get props => [senderIp, senderName];
}

final class PresencePacket extends WakiPacket {
  final bool isTalking;

  const PresencePacket({
    required super.senderIp,
    required super.senderName,
    required this.isTalking,
  });

  @override
  List<Object?> get props => [...super.props, isTalking];
}

final class AudioPacket extends WakiPacket {
  final List<double> samples;

  const AudioPacket({
    required super.senderIp,
    required super.senderName,
    required this.samples,
  });

  @override
  List<Object?> get props => [...super.props, samples];
}
