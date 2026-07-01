import 'package:equatable/equatable.dart';

class ChannelUser extends Equatable {
  final String id;
  final String name;
  final bool isTalking;
  final DateTime lastSeen;

  const ChannelUser({
    required this.id,
    required this.name,
    required this.isTalking,
    required this.lastSeen,
  });

  ChannelUser copyWith({
    String? id,
    String? name,
    bool? isTalking,
    DateTime? lastSeen,
  }) =>
      ChannelUser(
        id: id ?? this.id,
        name: name ?? this.name,
        isTalking: isTalking ?? this.isTalking,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  @override
  List<Object?> get props => [id, name, isTalking, lastSeen];
}
