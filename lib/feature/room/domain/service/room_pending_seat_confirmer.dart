import '../entity/held_seat_name.dart';
import '../entity/room.dart';
import '../repository/room_repository.dart';
import 'room_member_transport_identity.dart';

/// Settles an invite seat once its owner has proven, on the live transport,
/// that they are the member holding it — the mark, and the name.
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
/// **The name is the seat's other half (R27b).** A host cannot learn a
/// joiner's name any other way: it opened the seat before anyone could say who
/// would take it, and the joining phone never replies. So the joiner's own
/// phone signs what it calls itself, beside the route proof and under the same
/// certified key, and that name replaces the placeholder here. It is a
/// self-claim — but a self-claim nobody else on the network can forge, which
/// is exactly as strong as "what should we call you" deserves to be.
///
/// It can only ever write display metadata onto a member the roster already
/// holds — `RoomPeerMemberBindingRegistry.bind` refuses an id that is not
/// already an admitted member, so nothing here can create a seat, grant a
/// right, or change authorization. The worst a fault can do is leave a seat
/// pending, which is exactly where it started.
final class RoomPendingSeatConfirmer {
  RoomPendingSeatConfirmer({required this.rooms, required this.roomId});

  final RoomRepository rooms;
  final RoomId roomId;

  /// What this session has already tried to write for each member, so a proof
  /// arriving on every challenge cycle does not re-read storage once there is
  /// nothing left to say.
  ///
  /// Keyed by the name that came with the proof rather than by member alone,
  /// because the two facts settle at different times: a peer on a build older
  /// than R27b confirms its seat and never sends a name, and its later proofs
  /// must not each cost a storage read. A peer that does send one is handled
  /// on the next proof after the mark, then never again — and a name that
  /// changes mid-session is a new entry, so it lands rather than being
  /// swallowed by the cache.
  final Map<RoomMemberId, String?> _handled = {};

  bool _disposed = false;

  /// Records that [memberId] has been cryptographically proven present, and
  /// puts [displayName] on their row when they signed one.
  ///
  /// Returns true only when this call is what changed the roster, so a caller
  /// can tell "the seat is now confirmed" from "it already was". Never throws:
  /// a storage failure here must not be able to touch a live call, and the
  /// next proof will simply try again.
  Future<bool> confirm(RoomMemberId memberId, {String? displayName}) async {
    final name = displayName?.trim();
    if (_disposed ||
        (_handled.containsKey(memberId) && _handled[memberId] == name)) {
      return false;
    }
    try {
      final saved = await rooms.get(roomId);
      if (saved == null) return false;
      final index = saved.room.members.indexWhere(
        (member) => member.id == memberId,
      );
      final seat = index < 0 ? null : saved.room.members[index];
      // Not on the roster or withdrawn: nothing owed. A withdrawn seat
      // deliberately stays withdrawn — a revoked invite, or one whose hold ran
      // out, whose holder is still on the air is the host's decision to
      // reverse, not something evidence should quietly undo.
      if (seat == null || !seat.isActive) return false;

      // The placeholder is the only name this may overwrite. A real one was
      // either chosen by its owner or already learned from a proof, and a peer
      // renaming an occupied row is not something display metadata gets to do.
      final nameToWrite =
          name != null &&
              RoomMemberSignedName.isWellFormed(name) &&
              isHeldSeatPlaceholder(seat.displayName)
          ? name
          : null;
      if (!seat.pending && nameToWrite == null) {
        _handled[memberId] = name;
        return false;
      }

      // Never an empty name, whatever arrives. Storage rejects one outright —
      // `_decodeMember` treats a nameless member as a corrupt record and
      // `_decodeRoom` answers a corrupt record by dropping the **whole room**,
      // so writing one here would make a rider's room disappear.
      //
      // A seat that reaches this point with no name to write keeps its
      // placeholder, which `roomMemberDisplayName` unwrites at the point of
      // display. That remains the answer for a peer on a build that sends no
      // name at all.
      await rooms.updateMember(
        roomId,
        memberId,
        pending: false,
        displayName: nameToWrite,
      );
      _handled[memberId] = name;
      return true;
    } on Object {
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    _handled.clear();
  }
}

