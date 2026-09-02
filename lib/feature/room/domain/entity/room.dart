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
    this.pending = false,
  });

  final RoomMemberId id;
  final String displayName;
  final DateTime joinedAt;
  final RoomMemberKind kind;
  final DateTime? removedAt;

  /// A seat held open by an invite that nobody has walked through yet.
  ///
  /// One-scan entry forces the host to authorise a member *before* the QR is
  /// shown, because the joining phone never talks back — so the roster has a
  /// row for someone who may never arrive. Without this flag those rows are
  /// indistinguishable from real members, which is exactly how a host ends up
  /// looking at four people in a room containing two. A pending member is
  /// still durable and still authorised; it simply has not been seen yet, and
  /// [Room.confirmedMembers] is what the UI counts.
  ///
  /// Serialised as an optional key, so rooms written before this existed load
  /// as confirmed rather than being wiped by a schema bump.
  final bool pending;

  bool get isActive => removedAt == null;

  RoomMember copyWith({
    String? displayName,
    DateTime? removedAt,
    bool? pending,
  }) => RoomMember(
    id: id,
    displayName: displayName ?? this.displayName,
    joinedAt: joinedAt,
    kind: kind,
    removedAt: removedAt ?? this.removedAt,
    pending: pending ?? this.pending,
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

  /// Everyone who is still in the room.
  List<RoomMember> get activeMembers => [
    for (final member in members)
      if (member.isActive) member,
  ];

  /// Everyone who has actually turned up — the number the UI must show.
  ///
  /// Counting held-open invite seats here is what made one phone claim four
  /// people and the other two, so the distinction is load-bearing rather than
  /// cosmetic. Anything reporting "N members" wants this; anything managing
  /// invites wants [pendingMembers] alongside it.
  List<RoomMember> get confirmedMembers => [
    for (final member in members)
      if (member.isActive && !member.pending) member,
  ];

  /// Seats held open by an invite nobody has used yet.
  List<RoomMember> get pendingMembers => [
    for (final member in members)
      if (member.isActive && member.pending) member,
  ];

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
