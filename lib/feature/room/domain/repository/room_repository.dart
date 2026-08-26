import '../entity/room.dart';
import '../entity/room_accepted_join_snapshot.dart';
import '../entity/room_invitation.dart';
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

  /// Creates a bearer capability for an existing Room and durably records only
  /// its verifier. Raw invite secrets are returned to the caller for QR/link
  /// presentation but are never persisted by the repository.
  ///
  /// Only an active local membership with invite-management permission may
  /// issue capabilities. Transport bootstrap is optional/ephemeral and remains
  /// separate from Room identity and durable membership.
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  });

  /// Issuer-side verification/replay consumption for a presented capability.
  /// The resulting [VerifiedRoomInvitation] is the only authorization object
  /// accepted by [acceptVerifiedInvite].
  Future<VerifiedRoomInvitation?> verifyAndRedeemInvite(
    RoomInvitation invite, {
    required DateTime now,
  });

  /// Revokes a previously issued capability on this offline Room issuer.
  Future<void> revokeInvite(RoomInvitation invite);

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

  /// Persists issuer-provided durable Room state after the joiner has already
  /// correlated and verified an accepted invite response.
  ///
  /// The local member must already be present exactly once in [snapshot]. This
  /// operation never accepts a raw invite, short code, transport bootstrap or
  /// bearer secret, and never grants invite-management authority to the joiner.
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  });

  /// Leaves durable membership without deleting the saved room record.
  Future<SavedRoom> leave(RoomId id);

  Future<void> delete(RoomId id);

  Future<RoomId?> selectedRoomId();

  /// Explicit current-room selection. Null means no room selected.
  Future<void> select(RoomId? id);
}
