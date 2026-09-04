import '../entity/room.dart';
import '../entity/room_accepted_join_snapshot.dart';
import '../entity/room_invitation.dart';
import '../service/room_invitation_ledger.dart';

abstract interface class RoomRepository {
  /// Fires once after every durable change to the saved Rooms on this phone —
  /// a create, a rename, an archive, a roster edit, a delete, a selection.
  ///
  /// A ping, never a payload. The event carries nothing and a listener answers
  /// it by re-reading whatever it is showing, so a subscriber that starts late
  /// or misses an event is still correct the moment the next one lands.
  ///
  /// This exists because a widget's lifecycle cannot be trusted to say "you
  /// are being looked at again". A route sitting *under* a pushed one is never
  /// rebuilt and gets no dependency change when that route pops, which is how
  /// the landing screen went on offering a Room the user had just deleted one
  /// screen up. Storage is the only thing that knows the answer changed, so
  /// storage is what says so.
  Stream<void> get changes;

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
  ///
  /// [pending] marks the new row as a seat held open by an invite that nobody
  /// has walked through yet — the normal case for one-scan entry, where the
  /// host has to authorise a member before the QR can exist. It stays out of
  /// the member count until someone actually arrives.
  ///
  /// [heldUntil] is when that hold lapses, and callers opening a seat should
  /// pass the issuing invite's own expiry: past it the code cannot be
  /// redeemed, so the seat can never be claimed and stops being a seat.
  /// Ignored unless [pending]. Omitting it holds the seat indefinitely, which
  /// is what every seat opened before R27c does.
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
    bool pending,
    DateTime? heldUntil,
  });

  /// Edits durable display metadata for one member of a Room.
  ///
  /// Display metadata only: this can never change authorization, membership
  /// validity or transport identity. Used to put a joiner's own name on their
  /// row instead of the placeholder the host had to invent, and to mark an
  /// invite seat confirmed once its owner turns up.
  ///
  /// Clearing [pending] also releases the seat's hold: a seat somebody is
  /// standing in is not being kept for anyone, and a hold left behind would
  /// let a confirmed member's row expire.
  Future<SavedRoom> updateMember(
    RoomId id,
    RoomMemberId memberId, {
    String? displayName,
    bool? pending,
  });

  /// Withdraws a member from the roster, including an unused invite seat.
  ///
  /// Never applies to the local membership — leaving is [leave], which also
  /// tears down the local relationship rather than only the roster row.
  Future<SavedRoom> removeMember(RoomId id, RoomMemberId memberId);

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
