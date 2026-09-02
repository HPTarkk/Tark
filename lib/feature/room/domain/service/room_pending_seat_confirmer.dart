import '../entity/room.dart';
import '../repository/room_repository.dart';

/// Clears an invite seat's pending mark once its owner has proven, on the live
/// transport, that they are the member holding it.
///
/// One-scan entry forces a host to open a seat *before* it can know who will
/// take it, so every invite starts as a placeholder that must not be counted
/// (R7, R11). R7 closed that loop from the joiner's side: the joining phone
/// writes its own name over the placeholder and clears the mark. That leaves a
/// gap this closes — a rider who joins, rides, and never once opens the Room
/// screen leaves the seat pending forever, and the host has to reason about a
/// roster that says "open seat" for someone they are talking to.
///
/// **The evidence is stronger than what R7 settles on, not weaker.** This runs
/// only off a verified route binding: an issuer-certified member certificate,
/// signed over a challenge token this device itself issued on the current
/// attachment. A name in a settings field is a claim; this is a signature.
///
/// It can only ever clear a flag on a member the roster already holds —
/// `RoomPeerMemberBindingRegistry.bind` refuses an id that is not already an
/// admitted member, so nothing here can create a seat, grant a right, or change
/// authorization. The worst a fault can do is leave a seat pending, which is
/// exactly where it started.
final class RoomPendingSeatConfirmer {
  RoomPendingSeatConfirmer({required this.rooms, required this.roomId});

  final RoomRepository rooms;
  final RoomId roomId;

  /// Members already settled in this session, so a proof arriving on every
  /// challenge cycle does not re-read storage once a seat is confirmed.
  ///
  /// Safe to cache because the mark is one-way: an invite seat goes pending →
  /// confirmed and never back. A member who leaves is removed from the roster
  /// outright rather than returned to pending.
  final Set<RoomMemberId> _settled = {};

  bool _disposed = false;

  /// Records that [memberId] has been cryptographically proven present.
  ///
  /// Returns true only when this call is what changed the roster, so a caller
  /// can tell "the seat is now confirmed" from "it already was". Never throws:
  /// a storage failure here must not be able to touch a live call, and the
  /// next proof will simply try again.
  Future<bool> confirm(RoomMemberId memberId) async {
    if (_disposed || _settled.contains(memberId)) return false;
    try {
      final saved = await rooms.get(roomId);
      if (saved == null) return false;
      final index = saved.room.members.indexWhere(
        (member) => member.id == memberId,
      );
      final seat = index < 0 ? null : saved.room.members[index];
      // Not on the roster, already confirmed, or withdrawn: nothing owed. A
      // withdrawn seat deliberately stays withdrawn — a revoked invite whose
      // holder is still on the air is the host's decision to reverse, not
      // something evidence should quietly undo.
      if (seat == null || !seat.isActive || !seat.pending) {
        if (seat != null && seat.isActive) _settled.add(memberId);
        return false;
      }

      // Only the mark. The name stays exactly as stored, because storage
      // rejects an empty one outright — `_decodeMember` treats a nameless
      // member as a corrupt record and `_decodeRoom` answers a corrupt record
      // by dropping the **whole room**. Clearing the placeholder here would
      // have made a rider's room disappear.
      //
      // The placeholder is instead unwritten at the point of display, by
      // `roomMemberDisplayName`. That also fixes it for rooms that already
      // have a confirmed seat carrying one.
      await rooms.updateMember(roomId, memberId, pending: false);
      _settled.add(memberId);
      return true;
    } on Object {
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _settled.clear();
  }
}
