import '../../domain/entity/room.dart';
import '../../domain/service/room_member_transport_identity.dart';
import 'room_transport_identity_secure_store.dart';

/// Owns local cryptographic identity material across one durable Room membership.
///
/// Private member/issuer keys never cross this boundary. Join requests expose
/// only the member public key and accepted responses expose only the issuer-
/// signed certificate. Ordinary members with missing secure material fail
/// closed; only a Room membership that can manage invites may provision an
/// issuer identity locally.
final class RoomTransportIdentityLifecycle {
  RoomTransportIdentityLifecycle({
    required RoomTransportIdentitySecureStore store,
    RoomMemberTransportIdentityCrypto? crypto,
  }) : _store = store,
       _crypto = crypto ?? RoomMemberTransportIdentityCrypto();

  final RoomTransportIdentitySecureStore _store;
  final RoomMemberTransportIdentityCrypto _crypto;

  Future<RoomTransportIdentityMaterial> ensureLocalIdentity(
    SavedRoom saved,
  ) async {
    final memberId = saved.membership.localMemberId;
    final existing = await _store.read(
      roomId: saved.room.id,
      memberId: memberId,
    );
    if (existing != null) return existing;
    if (!saved.membership.active || !saved.membership.canManageInvites) {
      throw StateError('Room transport identity is unavailable');
    }

    final issuer = await _crypto.generateKeyPair();
    final member = await _crypto.generateKeyPair();
    final certificate = await _crypto.issueCertificate(
      roomId: saved.room.id,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    );
    final material = RoomTransportIdentityMaterial(
      memberKeyPair: member,
      certificate: certificate,
      issuerKeyPair: issuer,
    );
    await _store.write(
      roomId: saved.room.id,
      memberId: memberId,
      material: material,
    );
    return material;
  }

  Future<RoomMemberTransportKeyPair> createPendingMemberKeyPair() =>
      _crypto.generateKeyPair();

  Future<RoomMemberTransportCertificate> issueMemberCertificate({
    required SavedRoom issuerRoom,
    required RoomMemberId memberId,
    required List<int> memberPublicKey,
  }) async {
    if (!issuerRoom.membership.active ||
        !issuerRoom.membership.canManageInvites) {
      throw StateError('Local Room membership cannot issue certificates');
    }
    final issuerMaterial = await ensureLocalIdentity(issuerRoom);
    final issuer = issuerMaterial.issuerKeyPair;
    if (issuer == null) {
      throw StateError('Room issuer key is unavailable');
    }
    return _crypto.issueCertificate(
      roomId: issuerRoom.room.id,
      memberId: memberId,
      memberPublicKey: memberPublicKey,
      issuer: issuer,
    );
  }

  Future<void> persistJoinedIdentity({
    required SavedRoom saved,
    required RoomMemberTransportKeyPair memberKeyPair,
    required RoomMemberTransportCertificate certificate,
  }) async {
    final roomId = saved.room.id;
    final memberId = saved.membership.localMemberId;
    if (certificate.roomId != roomId || certificate.memberId != memberId) {
      throw const FormatException('joined Room transport identity scope');
    }
    if (!_sameBytes(certificate.memberPublicKey, memberKeyPair.publicKey)) {
      throw const FormatException('joined Room transport identity key');
    }
    final verified = await _crypto.verifyCertificate(
      certificate: certificate,
      expectedIssuerPublicKey: certificate.issuerPublicKey,
    );
    if (!verified) {
      throw const FormatException(
        'joined Room transport certificate signature',
      );
    }
    await _store.write(
      roomId: roomId,
      memberId: memberId,
      material: RoomTransportIdentityMaterial(
        memberKeyPair: memberKeyPair,
        certificate: certificate,
      ),
    );
  }

  Future<RoomTransportIdentityMaterial?> readLocalIdentity(SavedRoom saved) =>
      _store.read(
        roomId: saved.room.id,
        memberId: saved.membership.localMemberId,
      );

  Future<void> deleteLocalIdentity(SavedRoom saved) => _store.delete(
    roomId: saved.room.id,
    memberId: saved.membership.localMemberId,
  );
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var index = 0; index < a.length; index += 1) {
    diff |= a[index] ^ b[index];
  }
  return diff == 0;
}
