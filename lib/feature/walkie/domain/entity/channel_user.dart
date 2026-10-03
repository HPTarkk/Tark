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

  /// The avatar this member announced in its presence packets (see
  /// `AvatarCatalog`), or null when it has none or its build predates
  /// avatars.
  final int? avatarId;

  /// Whether this member's presence says their subscription is running, or
  /// null when nothing has said either way yet (audio carries no profile).
  final bool? isPremium;

  const ChannelUser({
    required this.id,
    required this.name,
    required this.isTalking,
    required this.lastSeen,
    this.role = SessionRole.unknown,
    this.avatarId,
    this.isPremium,
  });

  ChannelUser copyWith({
    String? id,
    String? name,
    bool? isTalking,
    DateTime? lastSeen,
    SessionRole? role,
    int? avatarId,
    bool? isPremium,
  }) => ChannelUser(
    id: id ?? this.id,
    name: name ?? this.name,
    isTalking: isTalking ?? this.isTalking,
    lastSeen: lastSeen ?? this.lastSeen,
    role: role ?? this.role,
    avatarId: avatarId ?? this.avatarId,
    isPremium: isPremium ?? this.isPremium,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    isTalking,
    lastSeen,
    role,
    avatarId,
    isPremium,
  ];
}
