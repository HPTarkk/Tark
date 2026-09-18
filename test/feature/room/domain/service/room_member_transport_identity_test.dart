import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  final otherRoomId = RoomId('b' * 32);
  const memberId = RoomMemberId('cccccccccccccccccccccccc');

  Future<
    ({
      RoomMemberTransportKeyPair issuer,
      RoomMemberTransportKeyPair member,
      RoomMemberTransportCertificate certificate,
    })
  >
  identity() async {
    final issuer = await crypto.generateKeyPair();
    final member = await crypto.generateKeyPair();
    final certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    );
    return (issuer: issuer, member: member, certificate: certificate);
  }

  test(
    'issuer certificate round-trips and verifies only under trusted root',
    () async {
      final value = await identity();
      final decoded = RoomMemberTransportCertificate.decode(
        value.certificate.encode(),
      );

      expect(decoded.roomId, roomId);
      expect(decoded.memberId, memberId);
      expect(decoded.memberPublicKey, value.member.publicKey);
      expect(
        await crypto.verifyCertificate(
          certificate: decoded,
          expectedIssuerPublicKey: value.issuer.publicKey,
        ),
        isTrue,
      );

      final attacker = await crypto.generateKeyPair();
      expect(
        await crypto.verifyCertificate(
          certificate: decoded,
          expectedIssuerPublicKey: attacker.publicKey,
        ),
        isFalse,
      );
    },
  );

  test(
    'matched heartbeat proof is bound to room token and session epoch',
    () async {
      final value = await identity();
      final proof = await crypto.signProof(
        certificate: value.certificate,
        member: value.member,
        token: 41,
        sessionEpoch: 9,
      );
      final decoded = RoomMemberTransportProof.decode(proof.encode());

      expect(
        await crypto.verifyProof(
          proof: decoded,
          expectedRoomId: roomId,
          expectedIssuerPublicKey: value.issuer.publicKey,
          expectedToken: 41,
          expectedSessionEpoch: 9,
        ),
        isTrue,
      );
      expect(
        await crypto.verifyProof(
          proof: decoded,
          expectedRoomId: roomId,
          expectedIssuerPublicKey: value.issuer.publicKey,
          expectedToken: 42,
          expectedSessionEpoch: 9,
        ),
        isFalse,
      );
      expect(
        await crypto.verifyProof(
          proof: decoded,
          expectedRoomId: roomId,
          expectedIssuerPublicKey: value.issuer.publicKey,
          expectedToken: 41,
          expectedSessionEpoch: 10,
        ),
        isFalse,
      );
      expect(
        await crypto.verifyProof(
          proof: decoded,
          expectedRoomId: otherRoomId,
          expectedIssuerPublicKey: value.issuer.publicKey,
          expectedToken: 41,
          expectedSessionEpoch: 9,
        ),
        isFalse,
      );
    },
  );

  test(
    'member cannot sign proof with a key not named by certificate',
    () async {
      final value = await identity();
      final attacker = await crypto.generateKeyPair();

      await expectLater(
        crypto.signProof(
          certificate: value.certificate,
          member: attacker,
          token: 1,
          sessionEpoch: 1,
        ),
        throwsArgumentError,
      );
    },
  );

  test('tampered certificate or proof fails closed', () async {
    final value = await identity();
    final proof = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 7,
      sessionEpoch: 3,
    );
    final tamperedCertificate = RoomMemberTransportCertificate(
      roomId: value.certificate.roomId,
      memberId: const RoomMemberId('dddddddddddddddddddddddd'),
      memberPublicKey: value.certificate.memberPublicKey,
      issuerPublicKey: value.certificate.issuerPublicKey,
      issuerSignature: value.certificate.issuerSignature,
    );
    expect(
      await crypto.verifyCertificate(
        certificate: tamperedCertificate,
        expectedIssuerPublicKey: value.issuer.publicKey,
      ),
      isFalse,
    );

    final tamperedProof = RoomMemberTransportProof(
      certificate: proof.certificate,
      token: proof.token,
      sessionEpoch: proof.sessionEpoch,
      memberSignature: [
        ...proof.memberSignature.take(proof.memberSignature.length - 1),
        proof.memberSignature.last ^ 0x01,
      ],
    );
    expect(
      await crypto.verifyProof(
        proof: tamperedProof,
        expectedRoomId: roomId,
        expectedIssuerPublicKey: value.issuer.publicKey,
        expectedToken: 7,
        expectedSessionEpoch: 3,
      ),
      isFalse,
    );
  });

  test('key material decoder rejects malformed key sizes', () {
    expect(
      () =>
          RoomMemberTransportKeyPair.decode(privateKey: 'AA', publicKey: 'AA'),
      throwsFormatException,
    );
  });
}
