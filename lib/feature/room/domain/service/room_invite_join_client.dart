import '../entity/room.dart';
import 'room_accepted_join_snapshot.dart';
import 'room_invite_join_exchange.dart';

/// Joiner-side verifier for an issuer response to a previously created Room
/// invite request.
///
/// A transport response is not accepted merely because it decodes. It must be
/// correlated to the exact outstanding request and to the Room/member identity
/// deterministically implied by that request's invitation. The issuer-provided
/// durable snapshot must also name the same Room and contain the accepted local
/// member before it can become importable local state.
final class RoomInviteJoinClient {
  const RoomInviteJoinClient();

  RoomInviteJoinGrant? verifyAcceptedResponse({
    required RoomInviteJoinRequest request,
    required String encodedResponse,
  }) {
    final RoomInviteJoinResponse response;
    try {
      response = RoomInviteJoinResponse.decode(encodedResponse);
    } on FormatException {
      return null;
    }
    if (response.status != RoomInviteJoinResponseStatus.accepted) return null;
    if (response.requestId != request.requestId) return null;
    if (response.roomId != request.invitation.roomId) return null;

    final expectedMemberId = RoomMemberId(
      request.invitation.invitationId.substring(0, 24),
    );
    if (response.memberId != expectedMemberId) return null;

    final snapshot = response.snapshot;
    if (snapshot == null || snapshot.roomId != response.roomId) return null;
    final acceptedMembers = snapshot.members.where(
      (member) => member.memberId == expectedMemberId,
    );
    if (acceptedMembers.length != 1) return null;

    return RoomInviteJoinGrant(
      roomId: response.roomId!,
      memberId: expectedMemberId,
      displayName: request.displayName.trim(),
      snapshot: snapshot,
    );
  }
}

/// Correlated, issuer-accepted identity plus bounded durable Room state ready
/// for local persistence. Carries no invite secret or transport bootstrap data.
final class RoomInviteJoinGrant {
  const RoomInviteJoinGrant({
    required this.roomId,
    required this.memberId,
    required this.displayName,
    required this.snapshot,
  });

  final RoomId roomId;
  final RoomMemberId memberId;
  final String displayName;
  final RoomAcceptedJoinSnapshot snapshot;
}
