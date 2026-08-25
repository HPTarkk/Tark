import '../entity/room.dart';
import '../service/room_invitation_ledger.dart';

abstract interface class RoomRepository {
  Future<List<SavedRoom>> list({bool includeArchived = false});

  Future<SavedRoom?> get(RoomId id);

  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  });

  Future<SavedRoom> rename(RoomId id, String name);

  Future<SavedRoom> setArchived(RoomId id, bool archived);

  /// Canonical durable membership mutation for a verified Room invitation.
  ///
  /// Callers cannot authorize this operation with RoomId, display code, or a
  /// decoded raw invite. [VerifiedRoomInvitation] is created only by the
  /// issuer-side ledger after expiry/revocation/replay checks succeed.
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
  });

  /// Leaves durable membership without deleting the saved room record.
  Future<SavedRoom> leave(RoomId id);

  Future<void> delete(RoomId id);

  Future<RoomId?> selectedRoomId();

  /// Explicit current-room selection. Null means no room selected.
  Future<void> select(RoomId? id);
}
