import '../entity/room.dart';
import 'room_invite_join_exchange.dart';

/// Joiner-side verifier for an issuer response to a previously created Room
/// invite request.
///
/// A transport response is not accepted merely because it decodes. It must be
/// correlated to the exact outstanding request and to the Room/member identity
/// deterministically implied by that request's invitation. This prevents a
/// delayed, cross-room or forged accepted response from being imported into the
/// wrong local Room state.
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

    return RoomInviteJoinGrant(
      roomId: response.roomId!,
      memberId: expectedMemberId,
      displayName: request.displayName.trim(),
    );
  }
}

/// Correlated, issuer-accepted identity ready for the later local Room import
/// step. Carries no invite secret or transport bootstrap data.
final class RoomInviteJoinGrant {
  const RoomInviteJoinGrant({
    required this.roomId,
    required this.memberId,
    required this.displayName,
  });

  final RoomId roomId;
  final RoomMemberId memberId;
  final String displayName;
}
