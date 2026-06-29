import 'package:equatable/equatable.dart';

class ChannelUser extends Equatable {
  final String ip;
  final String name;
  final bool isTalking;
  final DateTime lastSeen;

  const ChannelUser({
    required this.ip,
    required this.name,
    required this.isTalking,
    required this.lastSeen,
  });

  ChannelUser copyWith({
    String? ip,
    String? name,
    bool? isTalking,
    DateTime? lastSeen,
  }) =>
      ChannelUser(
        ip: ip ?? this.ip,
        name: name ?? this.name,
        isTalking: isTalking ?? this.isTalking,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  @override
  List<Object?> get props => [ip, name, isTalking, lastSeen];
}
