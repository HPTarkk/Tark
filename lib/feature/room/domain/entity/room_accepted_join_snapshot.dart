import 'dart:convert';

import 'room.dart';

/// Bounded durable Room state an issuer may return only after a Room invite has
/// been verified and accepted.
///
/// This is deliberately transport-free: no invite secret, Wi-Fi credentials,
/// IP address, transport role or live reachability is serialized. It contains
/// only durable Room data needed by the accepted member to persist an honest
/// local Room instead of inventing names, roster entries or timestamps.
final class RoomAcceptedJoinSnapshot {
  RoomAcceptedJoinSnapshot({
    required this.roomId,
    required this.roomName,
    required this.roomCreatedAt,
    required this.roomUpdatedAt,
    required Iterable<RoomAcceptedJoinMember> members,
    this.grantsInviteManagement = false,
  }) : members = List.unmodifiable(members) {
    if (roomName.trim().isEmpty || roomName.trim().length > maxRoomNameLength) {
      throw ArgumentError.value(roomName, 'roomName', 'invalid room name');
    }
    if (roomUpdatedAt.toUtc().isBefore(roomCreatedAt.toUtc())) {
      throw ArgumentError('Room updatedAt precedes createdAt');
    }
    if (this.members.isEmpty || this.members.length > maxMembers) {
      throw ArgumentError.value(
        this.members.length,
        'members',
        'invalid roster size',
      );
    }
    final ids = this.members.map((member) => member.memberId.value).toSet();
    if (ids.length != this.members.length) {
      throw ArgumentError('duplicate RoomMemberId in accepted join snapshot');
    }
  }

  static const currentVersion = 1;
  static const maxMembers = 12;
  static const maxRoomNameLength = 120;
  static const maxDisplayNameLength = 80;
  static const maxEncodedLength = 6144;

  final RoomId roomId;
  final String roomName;
  final DateTime roomCreatedAt;
  final DateTime roomUpdatedAt;
  final List<RoomAcceptedJoinMember> members;

  /// Whether the accepted member may go on to invite people themselves.
  ///
  /// Off by default: an invite is a bearer capability, so handing one out has
  /// to be a decision the host takes per person rather than something every
  /// joiner inherits. It travels in the snapshot because the joining phone
  /// never replies — whatever authority it ends up with has to have been
  /// written into the code it scanned.
  final bool grantsInviteManagement;

  factory RoomAcceptedJoinSnapshot.fromSavedRoom(
    SavedRoom saved, {
    required RoomMemberId acceptedMemberId,
    bool grantsInviteManagement = false,
  }) {
    final active = saved.room.members
        .where((member) => member.isActive)
        .toList(growable: false);
    final accepted = active.where((member) => member.id == acceptedMemberId);
    if (accepted.length != 1) {
      throw StateError('accepted Room member is not active in issuer roster');
    }
    final selected = <RoomMember>[
      for (final member in active)
        if (member.id != acceptedMemberId) member,
    ].take(maxMembers - 1).toList(growable: true)..add(accepted.single);
    // The accepted member's own seat is pending on the issuer — one-scan entry
    // opens it before it can know who will take it — and it stops being
    // pending the moment this snapshot is handed over, because the person it
    // is being handed to is the one taking it. Settled here rather than at the
    // call site so no caller can forget and ship a phone that leaves itself
    // out of its own head count.
    final acceptedIndex = selected.length - 1;
    return RoomAcceptedJoinSnapshot(
      roomId: saved.room.id,
      roomName: saved.room.name.trim(),
      roomCreatedAt: saved.room.createdAt.toUtc(),
      roomUpdatedAt: saved.room.updatedAt.toUtc(),
      members: [
        for (var i = 0; i < selected.length; i++)
          i == acceptedIndex
              ? RoomAcceptedJoinMember.fromRoomMember(selected[i]).claimed()
              : RoomAcceptedJoinMember.fromRoomMember(selected[i]),
      ],
      grantsInviteManagement: grantsInviteManagement,
    );
  }

  String encode() {
    final payload = jsonEncode({
      'v': currentVersion,
      'roomId': roomId.value,
      'roomName': roomName.trim(),
      'createdAt': roomCreatedAt.toUtc().toIso8601String(),
      'updatedAt': roomUpdatedAt.toUtc().toIso8601String(),
      'members': members
          .map((member) => member.toJson())
          .toList(growable: false),
      // Written only when granted, so an ungranted code is byte-identical to
      // one minted before this field existed and stays as small as it was —
      // every byte here costs QR modules the camera has to resolve.
      if (grantsInviteManagement) 'invites': true,
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    if (encoded.length > maxEncodedLength) {
      throw const FormatException('accepted room snapshot too large');
    }
    return encoded;
  }

  static RoomAcceptedJoinSnapshot decode(String encoded) {
    final raw = encoded.trim();
    if (raw.isEmpty || raw.length > maxEncodedLength) {
      throw const FormatException('accepted room snapshot size');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      );
      if (value is! Map<String, dynamic> || value['v'] != currentVersion) {
        throw const FormatException('accepted room snapshot version');
      }
      final roomId = RoomId.parse(value['roomId'] as String? ?? '');
      final roomName = value['roomName'];
      final membersRaw = value['members'];
      final createdRaw = value['createdAt'];
      final updatedRaw = value['updatedAt'];
      if (roomId == null ||
          roomName is! String ||
          roomName.trim().isEmpty ||
          roomName.trim().length > maxRoomNameLength ||
          createdRaw is! String ||
          updatedRaw is! String ||
          membersRaw is! List ||
          membersRaw.isEmpty ||
          membersRaw.length > maxMembers) {
        throw const FormatException('accepted room snapshot fields');
      }
      final createdAt = DateTime.parse(createdRaw).toUtc();
      final updatedAt = DateTime.parse(updatedRaw).toUtc();
      if (updatedAt.isBefore(createdAt)) {
        throw const FormatException('accepted room snapshot timestamps');
      }
      final members = membersRaw
          .map(RoomAcceptedJoinMember.fromJson)
          .toList(growable: false);
      final ids = members.map((member) => member.memberId.value).toSet();
      if (ids.length != members.length) {
        throw const FormatException('duplicate accepted room member');
      }
      return RoomAcceptedJoinSnapshot(
        roomId: roomId,
        roomName: roomName.trim(),
        roomCreatedAt: createdAt,
        roomUpdatedAt: updatedAt,
        members: members,
        // Anything other than an explicit true is no grant, so a malformed or
        // absent field can only ever fail closed.
        grantsInviteManagement: value['invites'] == true,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('malformed accepted room snapshot');
    }
  }
}

final class RoomAcceptedJoinMember {
  const RoomAcceptedJoinMember({
    required this.memberId,
    required this.displayName,
    required this.joinedAt,
    required this.kind,
    this.pending = false,
    this.heldUntil,
  });

  final RoomMemberId memberId;
  final String displayName;
  final DateTime joinedAt;
  final RoomMemberKind kind;

  /// A seat the issuer has opened that nobody has walked through yet.
  ///
  /// Carried because the alternative is the two phones holding different
  /// rosters for the same Room. The issuer's other open seats are `active`, so
  /// they travel in this snapshot like everyone else — and arriving without
  /// the mark they turned into ordinary members on the joining phone, counted
  /// in its head count and rendered as a nameless person who is not there.
  ///
  /// The one seat this is never true for on arrival is the joiner's own: they
  /// are, by definition, standing in it. [RoomAcceptedJoinSnapshot.fromSavedRoom]
  /// settles that, so no caller has to remember to.
  final bool pending;

  /// When the issuer's hold on this seat lapses, for the same reason [pending]
  /// travels at all.
  ///
  /// Without it the two phones expire the same seat on different schedules —
  /// which is to say the joining phone never does, because it has no
  /// back-channel to be told. An unclaimed seat that clears itself on the host
  /// and not on the joiner is R27's roster divergence again, one phone over.
  final DateTime? heldUntil;

  factory RoomAcceptedJoinMember.fromRoomMember(RoomMember member) =>
      RoomAcceptedJoinMember(
        memberId: member.id,
        displayName: member.displayName.trim(),
        joinedAt: member.joinedAt.toUtc(),
        kind: member.kind,
        pending: member.pending,
        heldUntil: member.heldUntil?.toUtc(),
      );

  /// The same seat, with its held mark dropped because its owner has arrived.
  ///
  /// The hold goes with the mark: what it was counting down to was this.
  RoomAcceptedJoinMember claimed() => RoomAcceptedJoinMember(
    memberId: memberId,
    displayName: displayName,
    joinedAt: joinedAt,
    kind: kind,
  );

  Map<String, Object> toJson() => {
    'id': memberId.value,
    'displayName': displayName,
    'joinedAt': joinedAt.toUtc().toIso8601String(),
    'kind': kind.name,
    // Written only when true, so a roster with no open seats encodes to
    // exactly the bytes it did before this field existed — every byte here
    // costs QR modules a camera has to resolve — and a build that predates it
    // simply ignores the key.
    if (pending) 'pending': true,
    if (pending && heldUntil != null)
      'heldUntil': heldUntil!.toUtc().toIso8601String(),
  };

  static RoomAcceptedJoinMember fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('accepted room member');
    }
    final id = raw['id'];
    final displayName = raw['displayName'];
    final joinedAt = raw['joinedAt'];
    final kind = raw['kind'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.trim().length >
            RoomAcceptedJoinSnapshot.maxDisplayNameLength ||
        joinedAt is! String ||
        kind is! String) {
      throw const FormatException('accepted room member fields');
    }
    final memberKind = RoomMemberKind.values.where(
      (value) => value.name == kind,
    );
    if (memberKind.length != 1) {
      throw const FormatException('accepted room member kind');
    }
    return RoomAcceptedJoinMember(
      memberId: RoomMemberId(id),
      displayName: displayName.trim(),
      joinedAt: DateTime.parse(joinedAt).toUtc(),
      kind: memberKind.single,
      // Anything but an explicit true is a real member, which is what every
      // roster written before this field existed contains.
      pending: raw['pending'] == true,
      // A hold only means something on a seat that is being held. A malformed
      // or absent one holds indefinitely rather than expiring immediately,
      // which is the safe direction: the cost is a stale row, not a member
      // dropped off a roster the moment they arrive.
      heldUntil: raw['pending'] == true && raw['heldUntil'] is String
          ? DateTime.tryParse(raw['heldUntil'] as String)?.toUtc()
          : null,
    );
  }
}
