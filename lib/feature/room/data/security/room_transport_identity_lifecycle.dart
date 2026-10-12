import '../../../../core/utils/logger.dart';
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
    // Only the phone that holds the Room root key may mint one. A delegate
    // with a right to invite but no identity would otherwise found a second,
    // unrelated Room key and every member it then invited would be a stranger
    // to everybody else.
    if (!saved.membership.active ||
        !saved.membership.canManageInvites ||
        !saved.membership.ownsRoomKey) {
      throw StateError('Room transport identity is unavailable');
    }

    // Minting a fresh Room key is right for a Room nobody else has joined.
    // With other members it is still the only way this phone can invite again,
    // but every certificate it signed before stops verifying: those people
    // will hear this phone and never connect until they are invited again.
    // Silent, that looked like a Room that simply "stopped working".
    final others = saved.room.confirmedMembers
        .where((member) => member.id != memberId)
        .length;
    if (others > 0) {
      Logger.diagnostic(
        'room: identity missing on the Room owner; minting a new Room key — '
        '$others existing member(s) must be invited again',
      );
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

  /// Signs the certificate an invite hands to [memberId].
  ///
  /// The Room key holder signs with the root key. A member who was granted the
  /// right to invite signs with its own member key, carrying its own
  /// certificate as the delegation link everybody else will walk back to the
  /// root — so what this phone can hand out is bounded by what it was given.
  /// [grantInvite] passes the right on, and is refused when this phone could
  /// not itself pass it on.
  Future<RoomMemberTransportCertificate> issueMemberCertificate({
    required SavedRoom issuerRoom,
    required RoomMemberId memberId,
    required List<int> memberPublicKey,
    bool grantInvite = false,
  }) async {
    if (!issuerRoom.membership.active ||
        !issuerRoom.membership.canManageInvites) {
      throw StateError('Local Room membership cannot issue certificates');
    }
    final material = await ensureLocalIdentity(issuerRoom);
    final issuer = material.issuerKeyPair;
    if (issuer != null) {
      return _crypto.issueCertificate(
        roomId: issuerRoom.room.id,
        memberId: memberId,
        memberPublicKey: memberPublicKey,
        issuer: issuer,
        grantInvite: grantInvite,
      );
    }
    final own = material.certificate;
    if (!own.canIssue) {
      throw StateError('Room issuer key is unavailable');
    }
    // Re-checked here, not trusted from import: a chain that no longer walks
    // back to this Room's key would only produce members nobody accepts.
    if (!await _crypto.verifyCertificate(
      certificate: own,
      expectedIssuerPublicKey: own.rootIssuerPublicKey,
    )) {
      throw StateError('Room invite delegation does not verify');
    }
    return _crypto.issueCertificate(
      roomId: issuerRoom.room.id,
      memberId: memberId,
      memberPublicKey: memberPublicKey,
      issuer: material.memberKeyPair,
      issuerCertificate: own,
      grantInvite: grantInvite,
    );
  }

  /// Whether an invite from this phone may also carry the right to invite.
  ///
  /// Always for the Room key holder; for a delegate only while the chain has
  /// room for one more generation that can itself invite. Answers false
  /// rather than throwing when the identity cannot be read, which hides the
  /// choice instead of offering one that would fail.
  Future<bool> canGrantInvites(SavedRoom saved) async {
    if (!saved.membership.active || !saved.membership.canManageInvites) {
      return false;
    }
    try {
      final material = await ensureLocalIdentity(saved);
      if (material.issuerKeyPair != null) return true;
      return material.certificate.canGrantOnward;
    } catch (_) {
      return false;
    }
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
    // The whole chain, back to the Room key the invite names: a delegated
    // certificate whose issuer was never allowed to invite, or whose grant was
    // tampered with, fails here and the join is rolled back.
    final verified = await _crypto.verifyCertificate(
      certificate: certificate,
      expectedIssuerPublicKey: certificate.rootIssuerPublicKey,
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
