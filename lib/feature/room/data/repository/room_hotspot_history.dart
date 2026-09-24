import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/settings/settings_keys.dart';
import '../../domain/entity/room.dart';

/// Which member raised a Room's hotspot the last time it went live.
///
/// When Start finds no link between the phones, both of them have to agree on
/// who shows the connection code and who opens the camera — without being able
/// to talk yet. Each phone records the host of the last hotspot call, so both
/// read the same answer. A Room that has never gone live over a hotspot falls
/// back to its creator (see [electHost]).
///
/// Only a member id is stored, never network names or passwords.
class RoomHotspotHistory {
  RoomHotspotHistory({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static String _key(RoomId roomId) =>
      '${SettingsKeys.roomLastHotspotHostPrefix}${roomId.value}';

  Future<RoomMemberId?> lastHost(RoomId roomId) async {
    final raw = (await _prefs()).getString(_key(roomId));
    return raw == null ? null : RoomMemberId(raw);
  }

  Future<void> recordHost(RoomId roomId, RoomMemberId host) async {
    await (await _prefs()).setString(_key(roomId), host.value);
  }

  /// The member who should show the code: the last hotspot host while they
  /// are still a confirmed member, otherwise whoever created the Room. Invite
  /// seats nobody has claimed yet are never elected.
  Future<RoomMemberId?> electHost(SavedRoom saved) async {
    final active = saved.room.confirmedMembers;
    if (active.isEmpty) return null;
    final last = await lastHost(saved.room.id);
    if (last != null && active.any((member) => member.id == last)) {
      return last;
    }
    return creatorOf(saved);
  }

  /// The earliest-joined confirmed member, ties broken by id — the same order
  /// on every phone.
  static RoomMemberId? creatorOf(SavedRoom saved) {
    final members = saved.room.confirmedMembers.toList(growable: false)
      ..sort((a, b) {
        final byJoined = a.joinedAt.compareTo(b.joinedAt);
        return byJoined != 0 ? byJoined : a.id.value.compareTo(b.id.value);
      });
    return members.isEmpty ? null : members.first.id;
  }
}
