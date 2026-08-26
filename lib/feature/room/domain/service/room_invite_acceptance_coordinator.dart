import '../entity/room.dart';
import '../entity/room_invitation.dart';
import '../repository/room_repository.dart';

enum RoomInviteAcceptanceStatus { accepted, rejected, roomUnavailable }

/// Issuer-side application boundary for accepting a presented Room invite.
///
/// A decoded QR/link is only a bearer request. It cannot mutate membership
/// until the canonical repository verifies that this issuer actually created
/// the capability and that it is still valid, unrevoked and unreplayed.
/// Keeping both steps here prevents presentation/transport consumers from
/// accidentally treating RoomId, display code or a syntactically valid token
/// as authorization.
///
/// Transport bootstrap data stays outside this decision. Rotating hotspot
/// credentials therefore cannot change Room identity or durable membership.
final class RoomInviteAcceptanceCoordinator {
  const RoomInviteAcceptanceCoordinator(this.repository);

  final RoomRepository repository;

  Future<RoomInviteAcceptanceResult> accept({
    required RoomInvitation invitation,
    required String displayName,
    required DateTime now,
  }) async {
    // Unknown local RoomIds cannot be authorized by a self-contained token.
    // Fail closed before asking the issuer ledger to verify anything.
    if (await repository.get(invitation.roomId) == null) {
      return const RoomInviteAcceptanceResult.roomUnavailable();
    }

    final verified = await repository.verifyAndRedeemInvite(
      invitation,
      now: now.toUtc(),
    );
    if (verified == null) {
      return const RoomInviteAcceptanceResult.rejected();
    }

    final saved = await repository.acceptVerifiedInvite(
      verified,
      displayName: displayName,
      acceptedAt: now.toUtc(),
    );
    return RoomInviteAcceptanceResult.accepted(saved);
  }
}

final class RoomInviteAcceptanceResult {
  const RoomInviteAcceptanceResult.accepted(this.room)
    : status = RoomInviteAcceptanceStatus.accepted;

  const RoomInviteAcceptanceResult.rejected()
    : status = RoomInviteAcceptanceStatus.rejected,
      room = null;

  const RoomInviteAcceptanceResult.roomUnavailable()
    : status = RoomInviteAcceptanceStatus.roomUnavailable,
      room = null;

  final RoomInviteAcceptanceStatus status;
  final SavedRoom? room;

  bool get accepted => status == RoomInviteAcceptanceStatus.accepted;
}
