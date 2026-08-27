import '../entity/room.dart';
import '../entity/room_accepted_join_snapshot.dart';
import 'room_invite_join_exchange.dart';
import 'room_member_transport_identity.dart';

/// Joiner-side verifier for an issuer response to a previously created Room
/// invite request.
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

    final requestedPublicKey = request.memberTransportPublicKey;
    final certificate = response.transportCertificate;
    if (requestedPublicKey != null) {
      if (certificate == null ||
          certificate.roomId != response.roomId ||
          certificate.memberId != expectedMemberId ||
          !_sameBytes(certificate.memberPublicKey, requestedPublicKey)) {
        return null;
      }
    } else if (certificate != null) {
      return null;
    }

    return RoomInviteJoinGrant(
      roomId: response.roomId!,
      memberId: expectedMemberId,
      displayName: request.displayName.trim(),
      snapshot: snapshot,
      transportCertificate: certificate,
    );
  }
}

/// Correlated, issuer-accepted identity plus bounded durable Room state ready
/// for local persistence. Certificate material is public; private key material
/// remains exclusively in the in-memory orchestration result until secure write.
final class RoomInviteJoinGrant {
  const RoomInviteJoinGrant({
    required this.roomId,
    required this.memberId,
    required this.displayName,
    required this.snapshot,
    this.transportCertificate,
  });

  final RoomId roomId;
  final RoomMemberId memberId;
  final String displayName;
  final RoomAcceptedJoinSnapshot snapshot;
  final RoomMemberTransportCertificate? transportCertificate;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index += 1) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}
