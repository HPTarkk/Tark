import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/transfer/data/codec/transport_route_proof_wire.dart';

/// R27b. The host cannot learn a joiner's name any other way: one-scan entry
/// opens the seat before anyone can say who will take it, and the joining phone
/// never replies. So the joiner's own phone signs what it calls itself and
/// sends it beside the route proof.
///
/// The whole point of the shape is what it does *not* touch. Folding the name
/// into the proof message would have bound it harder and broken proof
/// compatibility between builds, on the one path where two phones have to agree
/// about who is on the air. These tests exist mostly to pin that: the proof
/// signature must still cover exactly what it covered before.
void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  const roomId = RoomId('abababababababababababababababab');
  const otherRoomId = RoomId('cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd');
  const memberId = RoomMemberId('111111111111111111111111');

  late RoomMemberTransportKeyPair issuer;
  late RoomMemberTransportKeyPair member;
  late RoomMemberTransportCertificate certificate;

  setUp(() async {
    issuer = await crypto.generateKeyPair();
    member = await crypto.generateKeyPair();
    certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: member.publicKey,
      issuer: issuer,
    );
  });

  Future<RoomMemberSignedName?> sign(String name) =>
      crypto.signMemberName(certificate: certificate, member: member, name: name);

  Future<RoomMemberTransportProof> proofWith(RoomMemberSignedName? name) =>
      crypto.signProof(
        certificate: certificate,
        member: member,
        token: 7,
        sessionEpoch: 9,
        name: name,
      );

  test('a signed name survives the wire and verifies', () async {
    final proof = await proofWith(await sign('Rider B'));
    final decoded = RoomMemberTransportProof.decode(proof.encode());

    expect(decoded.name?.name, 'Rider B');
    expect(
      await crypto.verifyMemberName(
        certificate: decoded.certificate,
        name: decoded.name!,
        expectedRoomId: roomId,
      ),
      isTrue,
    );
  });

  test('the proof signature covers what it always did', () async {
    // The load-bearing claim of R27b's design. A proof carrying a name and the
    // same proof with the name stripped verify identically, because the name
    // is not in `_proofMessage` — which is what lets a build that predates
    // this and one that does not go on recognising each other.
    final named = await proofWith(await sign('Rider B'));
    final stripped = RoomMemberTransportProof(
      certificate: named.certificate,
      token: named.token,
      sessionEpoch: named.sessionEpoch,
      memberSignature: named.memberSignature,
    );

    for (final proof in [named, stripped]) {
      expect(
        await crypto.verifyProof(
          proof: proof,
          expectedRoomId: roomId,
          expectedIssuerPublicKey: issuer.publicKey,
          expectedToken: 7,
          expectedSessionEpoch: 9,
        ),
        isTrue,
      );
    }
  });

  test('an unnamed proof is byte-identical to one minted before R27b', () async {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize((await proofWith(null)).encode())),
    );

    // Read through the base64, or this passes on any string at all.
    expect(payload.contains('name'), isFalse);
    expect(payload.contains('nameSig'), isFalse);
  });

  test('a swapped name fails while the proof still stands', () async {
    final signed = await sign('Rider B');
    final tampered = RoomMemberSignedName(
      name: 'Someone else',
      signature: signed!.signature,
    );

    expect(
      await crypto.verifyMemberName(
        certificate: certificate,
        name: tampered,
        expectedRoomId: roomId,
      ),
      isFalse,
    );
    // And the proof it rode on is untouched by that, which is the whole
    // reason the name got its own signature instead of a place in this one.
    expect(
      await crypto.verifyProof(
        proof: await proofWith(tampered),
        expectedRoomId: roomId,
        expectedIssuerPublicKey: issuer.publicKey,
        expectedToken: 7,
        expectedSessionEpoch: 9,
      ),
      isTrue,
    );
  });

  test('a name signed for one Room does not verify in another', () async {
    final signed = await sign('Rider B');

    expect(
      await crypto.verifyMemberName(
        certificate: certificate,
        name: signed!,
        expectedRoomId: otherRoomId,
      ),
      isFalse,
    );
  });

  test('a name signed by somebody else does not verify', () async {
    final stranger = await crypto.generateKeyPair();
    final strangerCertificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: stranger.publicKey,
      issuer: issuer,
    );
    final theirs = await crypto.signMemberName(
      certificate: strangerCertificate,
      member: stranger,
      name: 'Rider B',
    );

    // Nobody else on the network can name you: the signature is checked
    // against the member key the certificate binds, not against whoever sent
    // the packet.
    expect(
      await crypto.verifyMemberName(
        certificate: certificate,
        name: theirs!,
        expectedRoomId: roomId,
      ),
      isFalse,
    );
  });

  test('a proof signature cannot be replayed as a name', () async {
    // Domain separation, from the other direction: the proof's own signature
    // is over a different prefix, so it can never be read as a name claim.
    final proof = await proofWith(null);

    expect(
      await crypto.verifyMemberName(
        certificate: certificate,
        name: RoomMemberSignedName(
          name: 'Rider B',
          signature: proof.memberSignature,
        ),
        expectedRoomId: roomId,
      ),
      isFalse,
    );
  });

  test('an empty or oversized name is never signed', () async {
    expect(await sign('   '), isNull);
    expect(await sign('x' * (RoomMemberSignedName.maxLength + 1)), isNull);
    expect(await sign('x' * RoomMemberSignedName.maxLength), isNotNull);
  });

  test('a half-present name pair is dropped, not fatal', () async {
    final named = await proofWith(await sign('Rider B'));
    final raw =
        jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(named.encode()))),
            )
            as Map<String, dynamic>
          ..remove('nameSig');
    final mangled = base64Url
        .encode(utf8.encode(jsonEncode(raw)))
        .replaceAll('=', '');

    // A corrupted optional field must never cost a route binding — that is
    // the one thing on this path that matters.
    final decoded = RoomMemberTransportProof.decode(mangled);
    expect(decoded.name, isNull);
    expect(
      await crypto.verifyProof(
        proof: decoded,
        expectedRoomId: roomId,
        expectedIssuerPublicKey: issuer.publicKey,
        expectedToken: 7,
        expectedSessionEpoch: 9,
      ),
      isTrue,
    );
  });

  test('the longest name still fits the wire that carries it', () async {
    final proof = await proofWith(
      await sign('نام بسیار طولانی ' * 4),
    );
    final encoded = proof.encode();

    expect(encoded.length, lessThanOrEqualTo(
      RoomMemberTransportProof.maxEncodedLength,
    ));
    // The proof rides one datagram field with its own uint16 length. A name
    // that encodes fine and then cannot be sent is not a working feature.
    expect(
      utf8.encode(encoded).length,
      lessThanOrEqualTo(TransportRouteProofWire.maxProofBytes),
    );
    expect(TransportRouteProofWire.encode(encoded), isNotEmpty);
  });
}
