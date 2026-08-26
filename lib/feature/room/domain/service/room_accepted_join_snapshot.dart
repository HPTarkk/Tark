import 'dart:convert';

import '../entity/room.dart';

/// Bounded durable Room state an issuer may return only after a Room invite has
/// been verified and accepted.
///
/// This is deliberately transport-free: no invite secret, Wi-Fi credentials,
/// IP address, transport role or live reachability is serialized. It contains
/// only the durable Room identity/name and the active roster needed by the
/// accepted member to persist an honest local Room instead of inventing one.
final class RoomAcceptedJoinSnapshot {
  RoomAcceptedJoinSnapshot({
    required this.roomId,
    required this.roomName,
    required Iterable<RoomAcceptedJoinMember> members,
  }) : members = List.unmodifiable(members) {
    if (roomName.trim().isEmpty || roomName.trim().length > maxRoomNameLength) {
      throw ArgumentError.value(roomName, 'roomName', 'invalid room name');
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
  static const maxEncodedLength = 4096;

  final RoomId roomId;
  final String roomName;
  final List<RoomAcceptedJoinMember> members;

  factory RoomAcceptedJoinSnapshot.fromSavedRoom(
    SavedRoom saved, {
    required RoomMemberId acceptedMemberId,
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
    ].take(maxMembers - 1).toList(growable: true)
      ..add(accepted.single);
    return RoomAcceptedJoinSnapshot(
      roomId: saved.room.id,
      roomName: saved.room.name.trim(),
      members: selected.map(RoomAcceptedJoinMember.fromRoomMember),
    );
  }

  String encode() {
    final payload = jsonEncode({
      'v': currentVersion,
      'roomId': roomId.value,
      'roomName': roomName.trim(),
      'members': members
          .map((member) => member.toJson())
          .toList(growable: false),
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
      if (roomId == null ||
          roomName is! String ||
          roomName.trim().isEmpty ||
          roomName.trim().length > maxRoomNameLength ||
          membersRaw is! List ||
          membersRaw.isEmpty ||
          membersRaw.length > maxMembers) {
        throw const FormatException('accepted room snapshot fields');
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
        members: members,
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
    required this.kind,
  });

  final RoomMemberId memberId;
  final String displayName;
  final RoomMemberKind kind;

  factory RoomAcceptedJoinMember.fromRoomMember(RoomMember member) =>
      RoomAcceptedJoinMember(
        memberId: member.id,
        displayName: member.displayName.trim(),
        kind: member.kind,
      );

  Map<String, Object> toJson() => {
    'id': memberId.value,
    'displayName': displayName,
    'kind': kind.name,
  };

  static RoomAcceptedJoinMember fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('accepted room member');
    }
    final id = raw['id'];
    final displayName = raw['displayName'];
    final kind = raw['kind'];
    if (id is! String ||
        !RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.trim().length >
            RoomAcceptedJoinSnapshot.maxDisplayNameLength ||
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
      kind: memberKind.single,
    );
  }
}
