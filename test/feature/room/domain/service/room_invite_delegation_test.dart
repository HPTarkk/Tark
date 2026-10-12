import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/transfer/data/codec/transport_route_proof_wire.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

/// ITEM 10: the right to invite is signed, delegable only by someone who holds
/// it, and verified by every receiver back to the one Room key it trusts.
void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const aId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa01');
  const bId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa02');
  const cId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa03');
  const dId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa04');

  late RoomMemberTransportKeyPair root;
  late RoomMemberTransportKeyPair a;
  late RoomMemberTransportKeyPair b;
  late RoomMemberTransportKeyPair c;

  setUpAll(() async {
    root = await crypto.generateKeyPair();
    a = await crypto.generateKeyPair();
    b = await crypto.generateKeyPair();
    c = await crypto.generateKeyPair();
  });

  Future<RoomMemberTransportCertificate> rootIssued(
    RoomMemberId id,
    RoomMemberTransportKeyPair member, {
    bool grant = false,
  }) => crypto.issueCertificate(
    roomId: roomId,
    memberId: id,
    memberPublicKey: member.publicKey,
    issuer: root,
    grantInvite: grant,
  );

  Future<bool> verify(RoomMemberTransportCertificate certificate) =>
      crypto.verifyCertificate(
        certificate: certificate,
        expectedIssuerPublicKey: root.publicKey,
      );

  List<int> flipped(List<int> bytes) => [bytes.first ^ 0x01, ...bytes.skip(1)];

  group('grant and deny', () {
    test('the creator can grant, and the grant verifies', () async {
      final cert = await rootIssued(aId, a, grant: true);

      expect(cert.canInvite, isTrue);
      expect(cert.issuerChain, isEmpty);
      expect(cert.rootIssuerPublicKey, root.publicKey);
      expect(await verify(cert), isTrue);
    });

    test('the creator can deny, and the member cannot issue', () async {
      final cert = await rootIssued(aId, a);

      expect(cert.canInvite, isFalse);
      expect(cert.canIssue, isFalse);
      expect(await verify(cert), isTrue);
      await expectLater(
        crypto.issueCertificate(
          roomId: roomId,
          memberId: bId,
          memberPublicKey: b.publicKey,
          issuer: a,
          issuerCertificate: cert,
        ),
        throwsStateError,
      );
    });

    test(
      'a granted member invites, and everyone verifies back to the root',
      () async {
        final aCert = await rootIssued(aId, a, grant: true);
        final bCert = await crypto.issueCertificate(
          roomId: roomId,
          memberId: bId,
          memberPublicKey: b.publicKey,
          issuer: a,
          issuerCertificate: aCert,
        );

        expect(bCert.issuerChain, hasLength(1));
        expect(bCert.issuerPublicKey, a.publicKey);
        expect(bCert.rootIssuerPublicKey, root.publicKey);
        expect(bCert.canInvite, isFalse);
        expect(await verify(bCert), isTrue);

        // Another Room's key is not this one.
        final stranger = await crypto.generateKeyPair();
        expect(
          await crypto.verifyCertificate(
            certificate: bCert,
            expectedIssuerPublicKey: stranger.publicKey,
          ),
          isFalse,
        );
      },
    );

    test('the right can be passed on, two generations deep', () async {
      final aCert = await rootIssued(aId, a, grant: true);
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
        grantInvite: true,
      );
      expect(bCert.canGrantOnward, isFalse);
      expect(bCert.canIssue, isTrue);
      final cCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: cId,
        memberPublicKey: c.publicKey,
        issuer: b,
        issuerCertificate: bCert,
      );

      expect(cCert.issuerChain.map((link) => link.memberId), [aId, bId]);
      expect(await verify(bCert), isTrue);
      expect(await verify(cCert), isTrue);
      expect(cCert.canIssue, isFalse);
    });
  });

  group('privilege escalation', () {
    test('an ungranted member signing under its own key is refused', () async {
      final aCert = await rootIssued(aId, a);
      // Build the chain by hand, as a modified app would, with garbage where
      // the grant has to be.
      final forgedLink = RoomInviteDelegation(
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuerSignature: aCert.issuerSignature,
        inviteGrant: List.filled(64, 7),
      );
      final forged = await _signLeaf(
        crypto,
        roomId: roomId,
        memberId: bId,
        member: b,
        signer: a,
        chain: [forgedLink],
        root: root.publicKey,
      );

      expect(await verify(forged), isFalse);
    });

    test('a member cannot grant itself the right with its own key', () async {
      final aCert = await rootIssued(aId, a);
      // A self-signed "grant": the right message, the wrong signer.
      final selfGranted = await crypto.issueCertificate(
        roomId: roomId,
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuer: a,
        grantInvite: true,
      );
      final escalated = RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuerPublicKey: aCert.issuerPublicKey,
        issuerSignature: aCert.issuerSignature,
        inviteGrant: selfGranted.inviteGrant,
      );

      expect(await verify(escalated), isFalse);
    });

    test('a grant lifted from another member does not transfer', () async {
      final aGranted = await rootIssued(aId, a, grant: true);
      final bPlain = await rootIssued(bId, b);
      final lifted = RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuerPublicKey: bPlain.issuerPublicKey,
        issuerSignature: bPlain.issuerSignature,
        inviteGrant: aGranted.inviteGrant,
      );

      expect(await verify(lifted), isFalse);
    });

    test('a member who may invite but not grant cannot pass it on', () async {
      final aCert = await rootIssued(aId, a, grant: true);
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
        grantInvite: true,
      );

      await expectLater(
        crypto.issueCertificate(
          roomId: roomId,
          memberId: cId,
          memberPublicKey: c.publicKey,
          issuer: b,
          issuerCertificate: bCert,
          grantInvite: true,
        ),
        throwsStateError,
      );

      // And bypassing the issuer's own check buys nothing: a verifier refuses
      // a grant at the bottom of the chain.
      final forced = await _signLeaf(
        crypto,
        roomId: roomId,
        memberId: cId,
        member: c,
        signer: b,
        chain: [...bCert.issuerChain, bCert.asDelegation()],
        root: root.publicKey,
        grant: true,
      );
      expect(forced.issuerChain, hasLength(2));
      expect(await verify(forced), isFalse);
    });

    test('a chain longer than the format allows is refused', () async {
      final aCert = await rootIssued(aId, a, grant: true);
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
        grantInvite: true,
      );
      final cForced = await _signLeaf(
        crypto,
        roomId: roomId,
        memberId: cId,
        member: c,
        signer: b,
        chain: [...bCert.issuerChain, bCert.asDelegation()],
        root: root.publicKey,
        grant: true,
      );
      final d = await crypto.generateKeyPair();
      final dForced = await _signLeaf(
        crypto,
        roomId: roomId,
        memberId: dId,
        member: d,
        signer: c,
        chain: [...cForced.issuerChain, cForced.asDelegation()],
        root: root.publicKey,
      );

      expect(dForced.issuerChain, hasLength(3));
      expect(await verify(dForced), isFalse);
      expect(dForced.encode, throwsFormatException);
    });
  });

  group('tampering', () {
    test('a flipped grant fails the whole certificate', () async {
      final cert = await rootIssued(aId, a, grant: true);
      final tampered = RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuerPublicKey: cert.issuerPublicKey,
        issuerSignature: cert.issuerSignature,
        inviteGrant: flipped(cert.inviteGrant!),
      );

      expect(await verify(tampered), isFalse);
    });

    test('a grant added to an ungranted certificate fails', () async {
      final cert = await rootIssued(aId, a);
      final added = RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: aId,
        memberPublicKey: a.publicKey,
        issuerPublicKey: cert.issuerPublicKey,
        issuerSignature: cert.issuerSignature,
        inviteGrant: List.filled(64, 1),
      );

      expect(await verify(added), isFalse);
    });

    test('a tampered link anywhere in the chain fails', () async {
      final aCert = await rootIssued(aId, a, grant: true);
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
      );
      final link = bCert.issuerChain.single;
      RoomMemberTransportCertificate withLink(RoomInviteDelegation next) =>
          RoomMemberTransportCertificate(
            roomId: roomId,
            memberId: bId,
            memberPublicKey: b.publicKey,
            issuerPublicKey: bCert.issuerPublicKey,
            issuerSignature: bCert.issuerSignature,
            issuerChain: [next],
            chainRootPublicKey: root.publicKey,
          );

      expect(
        await verify(
          withLink(
            RoomInviteDelegation(
              memberId: link.memberId,
              memberPublicKey: link.memberPublicKey,
              issuerSignature: link.issuerSignature,
              inviteGrant: flipped(link.inviteGrant),
            ),
          ),
        ),
        isFalse,
      );
      expect(
        await verify(
          withLink(
            RoomInviteDelegation(
              memberId: link.memberId,
              memberPublicKey: link.memberPublicKey,
              issuerSignature: flipped(link.issuerSignature),
              inviteGrant: link.inviteGrant,
            ),
          ),
        ),
        isFalse,
      );
      expect(
        await verify(
          withLink(
            RoomInviteDelegation(
              memberId: cId,
              memberPublicKey: link.memberPublicKey,
              issuerSignature: link.issuerSignature,
              inviteGrant: link.inviteGrant,
            ),
          ),
        ),
        isFalse,
      );
    });

    test('a tampered delegated certificate on the wire fails', () async {
      final aCert = await rootIssued(aId, a, grant: true);
      final bCert = await crypto.issueCertificate(
        roomId: roomId,
        memberId: bId,
        memberPublicKey: b.publicKey,
        issuer: a,
        issuerCertificate: aCert,
        grantInvite: true,
      );
      final bytes = base64Url.decode(base64Url.normalize(bCert.encode()));
      // Every byte past the version: flipping any of them must either fail to
      // decode or fail to verify. Never a certificate that still verifies.
      for (var index = 1; index < bytes.length; index += 1) {
        final copy = [...bytes]..[index] ^= 0x01;
        RoomMemberTransportCertificate decoded;
        try {
          decoded = RoomMemberTransportCertificate.decode(
            base64Url.encode(copy).replaceAll('=', ''),
          );
        } on FormatException {
          continue;
        }
        expect(await verify(decoded), isFalse, reason: 'byte $index');
      }
    });
  });

  group('wire format', () {
    test(
      'an ungranted certificate encodes exactly as earlier builds did',
      () async {
        final cert = await rootIssued(aId, a);
        final json =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(cert.encode())),
                  ),
                )
                as Map<String, dynamic>;

        expect(json.keys, [
          'v',
          'roomId',
          'memberId',
          'memberKey',
          'issuerKey',
          'signature',
        ]);
        expect(json['v'], 1);
      },
    );

    test('a root grant stays v1 JSON with one additive key', () async {
      final cert = await rootIssued(aId, a, grant: true);
      final json =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(cert.encode())),
                ),
              )
              as Map<String, dynamic>;

      expect(json['v'], 1);
      expect(json['grant'], isA<String>());
      final decoded = RoomMemberTransportCertificate.decode(cert.encode());
      expect(decoded.inviteGrant, cert.inviteGrant);
      expect(await verify(decoded), isTrue);
    });

    test(
      'a legacy certificate without the field still decodes and verifies',
      () async {
        final cert = await rootIssued(aId, a);
        // Minted by hand exactly as the previous release wrote it.
        String b64(List<int> bytes) =>
            base64Url.encode(bytes).replaceAll('=', '');
        final legacy = b64(
          utf8.encode(
            jsonEncode({
              'v': 1,
              'roomId': roomId.value,
              'memberId': aId.value,
              'memberKey': b64(a.publicKey),
              'issuerKey': b64(root.publicKey),
              'signature': b64(cert.issuerSignature),
            }),
          ),
        );

        final decoded = RoomMemberTransportCertificate.decode(legacy);
        expect(decoded.canInvite, isFalse);
        expect(decoded.issuerChain, isEmpty);
        expect(await verify(decoded), isTrue);
      },
    );

    test(
      'a malformed grant field is refused, not read as "no grant"',
      () async {
        final cert = await rootIssued(aId, a);
        String b64(List<int> bytes) =>
            base64Url.encode(bytes).replaceAll('=', '');
        final raw = b64(
          utf8.encode(
            jsonEncode({
              'v': 1,
              'roomId': roomId.value,
              'memberId': aId.value,
              'memberKey': b64(a.publicKey),
              'issuerKey': b64(root.publicKey),
              'signature': b64(cert.issuerSignature),
              'grant': 'short',
            }),
          ),
        );

        expect(
          () => RoomMemberTransportCertificate.decode(raw),
          throwsFormatException,
        );
      },
    );

    test(
      'a delegated certificate round-trips as v2 and still verifies',
      () async {
        final aCert = await rootIssued(aId, a, grant: true);
        final bCert = await crypto.issueCertificate(
          roomId: roomId,
          memberId: bId,
          memberPublicKey: b.publicKey,
          issuer: a,
          issuerCertificate: aCert,
          grantInvite: true,
        );
        final cCert = await crypto.issueCertificate(
          roomId: roomId,
          memberId: cId,
          memberPublicKey: c.publicKey,
          issuer: b,
          issuerCertificate: bCert,
        );

        for (final cert in [bCert, cCert]) {
          final encoded = cert.encode();
          expect(
            base64Url.decode(base64Url.normalize(encoded)).first,
            RoomMemberTransportCertificate.delegatedVersion,
          );
          final decoded = RoomMemberTransportCertificate.decode(encoded);
          expect(decoded.issuerChain.length, cert.issuerChain.length);
          expect(decoded.issuerPublicKey, cert.issuerPublicKey);
          expect(decoded.rootIssuerPublicKey, root.publicKey);
          expect(decoded.canInvite, cert.canInvite);
          expect(await verify(decoded), isTrue);
        }
      },
    );

    test(
      'the deepest member still proves itself inside one control record',
      () async {
        final aCert = await rootIssued(aId, a, grant: true);
        final bCert = await crypto.issueCertificate(
          roomId: roomId,
          memberId: bId,
          memberPublicKey: b.publicKey,
          issuer: a,
          issuerCertificate: aCert,
          grantInvite: true,
        );
        final cCert = await crypto.issueCertificate(
          roomId: roomId,
          memberId: cId,
          memberPublicKey: c.publicKey,
          issuer: b,
          issuerCertificate: bCert,
        );
        final name = await crypto.signMemberName(
          certificate: cCert,
          member: c,
          name: 'ر' * 80,
        );
        final proof = await crypto.signProof(
          certificate: cCert,
          member: c,
          token: 0xffffffff,
          sessionEpoch: 0xffffffff,
          name: name,
        );
        final encoded = proof.encode();

        expect(
          utf8.encode(encoded).length,
          lessThanOrEqualTo(TransportRouteProofWire.maxProofBytes),
        );
        expect(
          await crypto.verifyProof(
            proof: RoomMemberTransportProof.decode(encoded),
            expectedRoomId: roomId,
            expectedIssuerPublicKey: root.publicKey,
            expectedToken: 0xffffffff,
            expectedSessionEpoch: 0xffffffff,
          ),
          isTrue,
        );
      },
    );
  });
}

/// Signs a leaf exactly the way a modified client would, skipping every check
/// [RoomMemberTransportIdentityCrypto.issueCertificate] makes, so the tests
/// exercise the verifier rather than the issuer's good manners.
Future<RoomMemberTransportCertificate> _signLeaf(
  RoomMemberTransportIdentityCrypto crypto, {
  required RoomId roomId,
  required RoomMemberId memberId,
  required RoomMemberTransportKeyPair member,
  required RoomMemberTransportKeyPair signer,
  required List<RoomInviteDelegation> chain,
  required List<int> root,
  bool grant = false,
}) async {
  // Re-use the real issuer for the signatures themselves (they are over the
  // right messages), then graft on whatever chain the attacker wants.
  final signed = await crypto.issueCertificate(
    roomId: roomId,
    memberId: memberId,
    memberPublicKey: member.publicKey,
    issuer: signer,
    grantInvite: grant,
  );
  return RoomMemberTransportCertificate(
    roomId: roomId,
    memberId: memberId,
    memberPublicKey: member.publicKey,
    issuerPublicKey: signer.publicKey,
    issuerSignature: signed.issuerSignature,
    inviteGrant: signed.inviteGrant,
    issuerChain: chain,
    chainRootPublicKey: root,
  );
}
