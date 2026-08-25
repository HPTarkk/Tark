import 'dart:math';

/// Durable identity for a logical room.
///
/// This is intentionally unrelated to ChannelId, SSID, IP, Bluetooth address,
/// display name or whichever device happens to host today's transport.
final class RoomId {
  const RoomId(this.value);

  final String value;

  static RoomId generate([Random? random]) {
    final rng = random ?? Random.secure();
    final out = StringBuffer();
    for (var i = 0; i < 32; i++) {
      out.write(rng.nextInt(16).toRadixString(16));
    }
    return RoomId(out.toString());
  }

  static RoomId? parse(String raw) {
    final value = raw.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) return null;
    return RoomId(value);
  }

  @override
  bool operator ==(Object other) => other is RoomId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class RoomMemberId {
  const RoomMemberId(this.value);

  final String value;

  static RoomMemberId generate([Random? random]) {
    final rng = random ?? Random.secure();
    final out = StringBuffer();
    for (var i = 0; i < 24; i++) {
      out.write(rng.nextInt(16).toRadixString(16));
    }
    return RoomMemberId(out.toString());
  }

  @override
  bool operator ==(Object other) =>
      other is RoomMemberId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

enum RoomMemberKind { member, guest }

/// Durable membership only. Live reachability belongs to SessionParticipant.
final class RoomMember {
  const RoomMember({
    required this.id,
    required this.displayName,
    required this.joinedAt,
    this.kind = RoomMemberKind.member,
    this.removedAt,
  });

  final RoomMemberId id;
  final String displayName;
  final DateTime joinedAt;
  final RoomMemberKind kind;
  final DateTime? removedAt;

  bool get isActive => removedAt == null;

  RoomMember copyWith({String? displayName, DateTime? removedAt}) => RoomMember(
    id: id,
    displayName: displayName ?? this.displayName,
    joinedAt: joinedAt,
    kind: kind,
    removedAt: removedAt ?? this.removedAt,
  );
}

/// The local user's durable relationship to a saved room.
final class RoomMembership {
  const RoomMembership({
    required this.localMemberId,
    required this.canManageInvites,
    this.active = true,
  });

  final RoomMemberId localMemberId;
  final bool canManageInvites;
  final bool active;

  RoomMembership copyWith({bool? canManageInvites, bool? active}) =>
      RoomMembership(
        localMemberId: localMemberId,
        canManageInvites: canManageInvites ?? this.canManageInvites,
        active: active ?? this.active,
      );
}

final class Room {
  const Room({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.members,
    this.archived = false,
    this.schemaVersion = currentSchemaVersion,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final RoomId id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RoomMember> members;
  final bool archived;

  Room copyWith({
    String? name,
    DateTime? updatedAt,
    List<RoomMember>? members,
    bool? archived,
  }) => Room(
    schemaVersion: schemaVersion,
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    members: List.unmodifiable(members ?? this.members),
    archived: archived ?? this.archived,
  );
}

final class SavedRoom {
  const SavedRoom({required this.room, required this.membership});

  final Room room;
  final RoomMembership membership;

  SavedRoom copyWith({Room? room, RoomMembership? membership}) => SavedRoom(
    room: room ?? this.room,
    membership: membership ?? this.membership,
  );
}
