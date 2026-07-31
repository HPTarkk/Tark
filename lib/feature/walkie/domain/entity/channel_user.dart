import 'package:equatable/equatable.dart';

import '../../../transfer/api/transfer_api.dart';

class ChannelUser extends Equatable {
  final String id;
  final String name;
  final bool isTalking;
  final DateTime lastSeen;

  /// The part this member announced in its own presence packets.
  /// [SessionRole.unknown] for a peer on a build that predates roles — the
  /// channel then simply doesn't label them.
  final SessionRole role;

  const ChannelUser({
    required this.id,
    required this.name,
    required this.isTalking,
    required this.lastSeen,
    this.role = SessionRole.unknown,
  });

  ChannelUser copyWith({
    String? id,
    String? name,
    bool? isTalking,
    DateTime? lastSeen,
    SessionRole? role,
  }) => ChannelUser(
    id: id ?? this.id,
    name: name ?? this.name,
    isTalking: isTalking ?? this.isTalking,
    lastSeen: lastSeen ?? this.lastSeen,
    role: role ?? this.role,
  );

  @override
  List<Object?> get props => [id, name, isTalking, lastSeen, role];
}
