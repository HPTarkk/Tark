import 'dart:convert';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entity/room.dart';
import '../../domain/entity/room_accepted_join_snapshot.dart';
import '../../domain/entity/room_invitation.dart';
import '../../domain/repository/room_repository.dart';
import '../../domain/service/room_invitation_ledger.dart';

/// Offline-first room storage.
///
/// Each room is persisted under its own key rather than one giant JSON blob, so
/// one corrupt/old record can be skipped without losing unrelated rooms. The
/// index contains only durable RoomIds; transport handles, hotspot credentials,
/// IP addresses and session state are never stored here.
@LazySingleton(as: RoomRepository)
class SharedPreferencesRoomRepository implements RoomRepository {
  static const _indexKey = 'rooms.v1.index';
  static const _selectedKey = 'rooms.v1.selected';
  static const _roomPrefix = 'rooms.v1.room.';
  static const _inviteLedgerPrefix = 'rooms.v1.invites.';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async {
    final prefs = await _prefs();
    final ids = _readIndex(prefs);
    final rooms = <SavedRoom>[];
    for (final id in ids) {
      final room = _readRoom(prefs, id);
      if (room == null) continue;
      if (!includeArchived && room.room.archived) continue;
      rooms.add(room);
    }
    rooms.sort((a, b) => b.room.updatedAt.compareTo(a.room.updatedAt));
    return List.unmodifiable(rooms);
  }

  @override
  Future<SavedRoom?> get(RoomId id) async {
    final prefs = await _prefs();
    return _readRoom(prefs, id);
  }

  @override
  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  }) async {
    final cleanName = _requiredText(name, 'room name');
    final cleanDisplayName = _requiredText(localDisplayName, 'display name');
    final now = DateTime.now().toUtc();
    final id = RoomId.generate();
    final memberId = RoomMemberId.generate();
    final saved = SavedRoom(
      room: Room(
        id: id,
        name: cleanName,
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(
            id: memberId,
            displayName: cleanDisplayName,
            joinedAt: now,
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: memberId,
        canManageInvites: true,
      ),
    );
    final prefs = await _prefs();
    await _writeRoom(prefs, saved);
    final ids = _readIndex(prefs).toList();
    if (!ids.contains(id)) ids.add(id);
    await prefs.setStringList(
      _indexKey,
      ids.map((item) => item.value).toList(),
    );
    return saved;
  }

  @override
  Future<SavedRoom> rename(RoomId id, String name) async {
    final current = await _require(id);
    final renamed = current.copyWith(
      room: current.room.copyWith(
        name: _requiredText(name, 'room name'),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await _save(renamed);
    return renamed;
  }

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) async {
    final current = await _require(id);
    final next = current.copyWith(
      room: current.room.copyWith(
        archived: archived,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await _save(next);
    return next;
  }

  @override
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  }) async {
    final room = await _require(id);
    _requireInviteManager(room);
    final invite = generateRoomInvitation(
      roomId: id,
      kind: kind,
      now: now,
      ttl: ttl,
      transportBootstrap: transportBootstrap,
    );
    final prefs = await _prefs();
    final ledger = _readInviteLedger(prefs, id);
    ledger.registerIssued(invite);
    await _writeInviteLedger(prefs, id, ledger);
    return invite;
  }

  @override
  Future<VerifiedRoomInvitation?> verifyAndRedeemInvite(
    RoomInvitation invite, {
    required DateTime now,
  }) async {
    final room = await _require(invite.roomId);
    _requireInviteManager(room);
    final prefs = await _prefs();
    final ledger = _readInviteLedger(prefs, invite.roomId);
    final verified = ledger.verifyAndRedeem(invite, now.toUtc());
    await _writeInviteLedger(prefs, invite.roomId, ledger);
    return verified;
  }

  @override
  Future<void> revokeInvite(RoomInvitation invite) async {
    final room = await _require(invite.roomId);
    _requireInviteManager(room);
    final prefs = await _prefs();
    final ledger = _readInviteLedger(prefs, invite.roomId);
    ledger.revoke(invite);
    await _writeInviteLedger(prefs, invite.roomId, ledger);
  }

  @override
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
  }) async {
    final invite = verified.invitation;
    final current = await _require(invite.roomId);
    final cleanDisplayName = _requiredText(displayName, 'display name');
    final now = acceptedAt.toUtc();

    final memberId = RoomMemberId(invite.invitationId.substring(0, 24));
    final memberKind = invite.kind == RoomInvitationKind.singleRideGuest
        ? RoomMemberKind.guest
        : RoomMemberKind.member;

    final members = current.room.members.toList(growable: true);
    final existingIndex = members.indexWhere((member) => member.id == memberId);
    if (existingIndex >= 0) {
      final existing = members[existingIndex];
      if (existing.isActive && existing.displayName != cleanDisplayName) {
        members[existingIndex] = existing.copyWith(
          displayName: cleanDisplayName,
        );
      }
    } else {
      members.add(
        RoomMember(
          id: memberId,
          displayName: cleanDisplayName,
          joinedAt: now,
          kind: memberKind,
        ),
      );
    }

    final next = current.copyWith(
      room: current.room.copyWith(members: members, updatedAt: now),
    );
    await _save(next);
    return next;
  }

  @override
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  }) async {
    final localMatches = snapshot.members.where(
      (member) => member.memberId == localMemberId,
    );
    if (localMatches.length != 1) {
      throw StateError('Accepted Room snapshot does not contain local member');
    }

    final saved = SavedRoom(
      room: Room(
        id: snapshot.roomId,
        name: _requiredText(snapshot.roomName, 'room name'),
        createdAt: snapshot.roomCreatedAt.toUtc(),
        updatedAt: snapshot.roomUpdatedAt.toUtc(),
        members: snapshot.members
            .map(
              (member) => RoomMember(
                id: member.memberId,
                displayName: _requiredText(member.displayName, 'display name'),
                joinedAt: member.joinedAt.toUtc(),
                kind: member.kind,
              ),
            )
            .toList(growable: false),
      ),
      membership: RoomMembership(
        localMemberId: localMemberId,
        canManageInvites: false,
      ),
    );

    final prefs = await _prefs();
    final existing = _readRoom(prefs, snapshot.roomId);
    if (existing != null &&
        existing.membership.localMemberId != localMemberId) {
      throw StateError('Room already belongs to another local membership');
    }
    await _writeRoom(prefs, saved);
    final ids = _readIndex(prefs).toList();
    if (!ids.contains(snapshot.roomId)) ids.add(snapshot.roomId);
    await prefs.setStringList(
      _indexKey,
      ids.map((item) => item.value).toList(),
    );
    return saved;
  }

  @override
  Future<SavedRoom> leave(RoomId id) async {
    final current = await _require(id);
    final now = DateTime.now().toUtc();
    final members = current.room.members
        .map(
          (member) => member.id == current.membership.localMemberId
              ? RoomMember(
                  id: member.id,
                  displayName: member.displayName,
                  joinedAt: member.joinedAt,
                  kind: member.kind,
                  removedAt: member.removedAt ?? now,
                )
              : member,
        )
        .toList(growable: false);
    final next = current.copyWith(
      room: current.room.copyWith(members: members, updatedAt: now),
      membership: current.membership.copyWith(active: false),
    );
    await _save(next);
    if (await selectedRoomId() == id) await select(null);
    return next;
  }

  @override
  Future<void> delete(RoomId id) async {
    final prefs = await _prefs();
    await prefs.remove('$_roomPrefix${id.value}');
    await prefs.remove('$_inviteLedgerPrefix${id.value}');
    final ids = _readIndex(prefs).where((item) => item != id).toList();
    await prefs.setStringList(
      _indexKey,
      ids.map((item) => item.value).toList(),
    );
    if (await selectedRoomId() == id) await select(null);
  }

  @override
  Future<RoomId?> selectedRoomId() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_selectedKey);
    if (raw == null) return null;
    final id = RoomId.parse(raw);
    if (id == null || _readRoom(prefs, id) == null) {
      await prefs.remove(_selectedKey);
      return null;
    }
    return id;
  }

  @override
  Future<void> select(RoomId? id) async {
    final prefs = await _prefs();
    if (id == null) {
      await prefs.remove(_selectedKey);
      return;
    }
    if (_readRoom(prefs, id) == null) {
      throw StateError('Cannot select an unknown room');
    }
    await prefs.setString(_selectedKey, id.value);
  }

  Future<SavedRoom> _require(RoomId id) async {
    final value = await get(id);
    if (value == null) throw StateError('Room not found');
    return value;
  }

  void _requireInviteManager(SavedRoom room) {
    if (!room.membership.active || !room.membership.canManageInvites) {
      throw StateError('Local membership cannot manage room invitations');
    }
  }

  RoomInvitationLedger _readInviteLedger(SharedPreferences prefs, RoomId id) {
    final raw = prefs.getString('$_inviteLedgerPrefix${id.value}');
    if (raw == null) return RoomInvitationLedger();
    try {
      return RoomInvitationLedger.decodeState(raw);
    } on FormatException {
      throw StateError('Room invitation ledger is corrupt');
    }
  }

  Future<void> _writeInviteLedger(
    SharedPreferences prefs,
    RoomId id,
    RoomInvitationLedger ledger,
  ) => prefs.setString('$_inviteLedgerPrefix${id.value}', ledger.encodeState());

  Future<void> _save(SavedRoom room) async {
    final prefs = await _prefs();
    await _writeRoom(prefs, room);
  }

  List<RoomId> _readIndex(SharedPreferences prefs) {
    final values = prefs.getStringList(_indexKey) ?? const <String>[];
    final seen = <String>{};
    final result = <RoomId>[];
    for (final raw in values) {
      final id = RoomId.parse(raw);
      if (id != null && seen.add(id.value)) result.add(id);
    }
    return result;
  }

  SavedRoom? _readRoom(SharedPreferences prefs, RoomId id) {
    final raw = prefs.getString('$_roomPrefix${id.value}');
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      if (json['schemaVersion'] != Room.currentSchemaVersion) return null;
      final parsedId = RoomId.parse(json['id'] as String? ?? '');
      if (parsedId == null || parsedId != id) return null;
      final membersRaw = json['members'];
      if (membersRaw is! List) return null;
      final members = membersRaw.map(_decodeMember).toList(growable: false);
      final membershipRaw = json['membership'];
      if (membershipRaw is! Map<String, dynamic>) return null;
      final localIdRaw = membershipRaw['localMemberId'];
      if (localIdRaw is! String || localIdRaw.isEmpty) return null;
      final room = Room(
        id: id,
        name: _requiredText(json['name'] as String? ?? '', 'room name'),
        createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toUtc(),
        members: members,
        archived: json['archived'] as bool? ?? false,
      );
      return SavedRoom(
        room: room,
        membership: RoomMembership(
          localMemberId: RoomMemberId(localIdRaw),
          canManageInvites: membershipRaw['canManageInvites'] as bool? ?? false,
          active: membershipRaw['active'] as bool? ?? true,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  RoomMember _decodeMember(Object? raw) {
    if (raw is! Map<String, dynamic>) throw const FormatException('member');
    final id = raw['id'];
    final name = raw['displayName'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty) {
      throw const FormatException('member fields');
    }
    final removed = raw['removedAt'];
    return RoomMember(
      id: RoomMemberId(id),
      displayName: name.trim(),
      joinedAt: DateTime.parse(raw['joinedAt'] as String).toUtc(),
      kind: raw['kind'] == 'guest'
          ? RoomMemberKind.guest
          : RoomMemberKind.member,
      removedAt: removed is String ? DateTime.parse(removed).toUtc() : null,
    );
  }

  Future<void> _writeRoom(SharedPreferences prefs, SavedRoom saved) async {
    await prefs.setString(
      '$_roomPrefix${saved.room.id.value}',
      jsonEncode({
        'schemaVersion': saved.room.schemaVersion,
        'id': saved.room.id.value,
        'name': saved.room.name,
        'createdAt': saved.room.createdAt.toIso8601String(),
        'updatedAt': saved.room.updatedAt.toIso8601String(),
        'archived': saved.room.archived,
        'members': saved.room.members
            .map(
              (member) => {
                'id': member.id.value,
                'displayName': member.displayName,
                'joinedAt': member.joinedAt.toIso8601String(),
                'kind': member.kind.name,
                if (member.removedAt != null)
                  'removedAt': member.removedAt!.toIso8601String(),
              },
            )
            .toList(growable: false),
        'membership': {
          'localMemberId': saved.membership.localMemberId.value,
          'canManageInvites': saved.membership.canManageInvites,
          'active': saved.membership.active,
        },
      }),
    );
  }

  String _requiredText(String value, String field) {
    final clean = value.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(value, field, 'must not be empty');
    }
    return clean;
  }
}
