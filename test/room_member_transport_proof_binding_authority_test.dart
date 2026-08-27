import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_proof_binding_authority.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';

void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const memberId = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');
  const otherMemberId = RoomMemberId('cccccccccccccccccccccccc');
  final at = DateTime.utc(2026, 8, 27, 8);

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

  test('valid proof binds admitted member', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
    );
    expect(
      authority.observeChallenge(
        peerKey: 'udp:10.0.0.2:41111',
        token: 41,
        sessionEpoch: 9,
        attachmentGeneration: 3,
        at: at,
      ),
      isTrue,
    );
    final proof = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 41,
      sessionEpoch: 9,
    );

    expect(
      await authority.verifyAndBind(
        peerKey: 'udp:10.0.0.2:41111',
        encodedProof: proof.encode(),
        attachmentGeneration: 3,
        at: at,
      ),
      isTrue,
    );
    expect(
      bindings.resolve('udp:10.0.0.2:41111', attachmentGeneration: 3),
      memberId,
    );
  });

  test('other route cannot steal challenge', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
    );
    authority.observeChallenge(
      peerKey: 'route-a',
      token: 7,
      sessionEpoch: 2,
      attachmentGeneration: 1,
      at: at,
    );
    final proof = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 7,
      sessionEpoch: 2,
    );

    expect(
      await authority.verifyAndBind(
        peerKey: 'route-b',
        encodedProof: proof.encode(),
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.length, 0);
  });

  test('wrong token consumes challenge and requires a fresh one', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
    );
    authority.observeChallenge(
      peerKey: 'route-a',
      token: 10,
      sessionEpoch: 4,
      attachmentGeneration: 1,
      at: at,
    );
    final wrong = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 11,
      sessionEpoch: 4,
    );
    expect(
      await authority.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: wrong.encode(),
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );

    final correct = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 10,
      sessionEpoch: 4,
    );
    expect(
      await authority.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: correct.encode(),
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.length, 0);
  });

  test('attachment replacement rejects delayed old-route proof', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
    );
    authority.observeChallenge(
      peerKey: 'old-route',
      token: 5,
      sessionEpoch: 6,
      attachmentGeneration: 2,
      at: at,
    );
    final proof = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 5,
      sessionEpoch: 6,
    );
    authority.replaceAttachment(3);

    expect(
      await authority.verifyAndBind(
        peerKey: 'old-route',
        encodedProof: proof.encode(),
        attachmentGeneration: 2,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.length, 0);
  });

  test('certificate cannot bind non-member', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(
      members: const [otherMemberId],
    );
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
    );
    authority.observeChallenge(
      peerKey: 'route-a',
      token: 20,
      sessionEpoch: 1,
      attachmentGeneration: 1,
      at: at,
    );
    final proof = await crypto.signProof(
      certificate: value.certificate,
      member: value.member,
      token: 20,
      sessionEpoch: 1,
    );

    expect(
      await authority.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: proof.encode(),
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    expect(bindings.length, 0);
  });

  test('expired and malformed challenges fail closed', () async {
    final value = await identity();
    final bindings = RoomPeerMemberBindingRegistry(members: const [memberId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: value.issuer.publicKey,
      challengeFor: const Duration(seconds: 5),
    );
    expect(
      authority.observeChallenge(
        peerKey: '',
        token: 1,
        sessionEpoch: 1,
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    expect(
      authority.observeChallenge(
        peerKey: 'route-a',
        token: 0x100000000,
        sessionEpoch: 1,
        attachmentGeneration: 1,
        at: at,
      ),
      isFalse,
    );
    authority.observeChallenge(
      peerKey: 'route-a',
      token: 1,
      sessionEpoch: 1,
      attachmentGeneration: 1,
      at: at,
    );

    expect(
      await authority.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: 'not-a-proof',
        attachmentGeneration: 1,
        at: at.add(const Duration(seconds: 6)),
      ),
      isFalse,
    );
    expect(bindings.length, 0);
  });
}
