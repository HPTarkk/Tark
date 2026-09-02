import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

/// Frozen v2 payload for [_fixture]. Pinned as a literal rather than recomputed
/// so that a change to the field order, the version byte, the flag bit or the
/// member-kind values fails here instead of in someone's hands, holding a phone
/// that will not scan a code the other phone minted.
const _goldenV2 =
    'tark-room:AgGrq6urq6urq6urq6urq6urIiIiIiIiIiIiIiIiAwoRGB8mLTQ7QklQV15l'
    'bHN6gYiPlp2kq7K5wMfO1dwLEhkgJy41PENKUVhfZm10e4KJkJeepayzusHIz9bd5B0k'
    'KzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09rh6O_2LzY9REtSWWBnbnV8g4qRmJ-mrbS7'
    'wsnQ197l7PP6AQgPFh0kKzI5QEdOVVxjanF4f4aNlJuiqbC3vsXM09rh6IDYyqi9dtLx'
    '5JCGNLKZ95CGNAxNb3JuaW5nIHJpZGUCERERERERERERERERANLx5JCGNBHZh9mF2LHY'
    'p9mHINin2YjZhCIiIiIiIiIiIiIiIgHS8eSQhjQJT3BlbiBzZWF0';

void main() {
  test(
    'round-trips every field, including a Persian name and a guest seat',
    () {
      final bundle = _fixture();
      final decoded = RoomDirectJoinBundle.decode(bundle.encode());

      expect(decoded.memberId, bundle.memberId);
      expect(decoded.expiresAt, bundle.expiresAt);
      expect(decoded.snapshot.roomId, bundle.snapshot.roomId);
      expect(decoded.snapshot.roomName, 'Morning ride');
      expect(decoded.snapshot.roomCreatedAt, bundle.snapshot.roomCreatedAt);
      expect(decoded.snapshot.roomUpdatedAt, bundle.snapshot.roomUpdatedAt);
      expect(decoded.snapshot.grantsInviteManagement, isTrue);
      expect(decoded.memberKeyPair.privateKey, bundle.memberKeyPair.privateKey);
      expect(decoded.memberKeyPair.publicKey, bundle.memberKeyPair.publicKey);
      expect(
        decoded.certificate.issuerSignature,
        bundle.certificate.issuerSignature,
      );
      expect(
        decoded.certificate.issuerPublicKey,
        bundle.certificate.issuerPublicKey,
      );
      expect(decoded.snapshot.members.first.displayName, 'همراه اول');
      expect(decoded.snapshot.members.first.kind, RoomMemberKind.member);
      expect(decoded.snapshot.members.last.kind, RoomMemberKind.guest);
      expect(
        decoded.snapshot.members.last.joinedAt,
        bundle.snapshot.members.last.joinedAt,
      );
    },
  );

  test('writes the pinned v2 layout', () {
    expect(_fixture().encode(), _goldenV2);
  });

  test('still reads the v1 envelope, and re-mints it as v2', () {
    final bundle = _fixture();
    final decoded = RoomDirectJoinBundle.decode(_encodeAsV1(bundle));

    expect(decoded.encode(), _goldenV2);
    expect(decoded.snapshot.roomName, 'Morning ride');
    expect(decoded.snapshot.grantsInviteManagement, isTrue);
    expect(decoded.snapshot.members.last.kind, RoomMemberKind.guest);
  });

  test('v2 is a quarter of the v1 payload it replaces', () {
    final bundle = _fixture();
    final legacy = _encodeAsV1(bundle).length;
    final compact = bundle.encode().length;

    expect(legacy, greaterThan(1500));
    expect(compact * 4, lessThan(legacy));
    // A two-seat invite has to stay inside the level-Q budget, or the centre
    // brand mark silently disappears from the common case.
    expect(
      compact,
      lessThanOrEqualTo(RoomDirectJoinBundle.brandableEncodedLength),
    );
  });

  test('a three-seat room still earns the brand mark', () {
    final encoded = _fixture(extraMembers: 1).encode().length;

    expect(
      encoded,
      lessThanOrEqualTo(RoomDirectJoinBundle.brandableEncodedLength),
    );
  });

  test('a full roster still encodes, unbranded', () {
    final encoded = _fixture(
      extraMembers: RoomAcceptedJoinSnapshot.maxMembers - 2,
    ).encode();

    expect(
      RoomDirectJoinBundle.decode(encoded).snapshot.members,
      hasLength(12),
    );
    expect(
      encoded.length,
      greaterThan(RoomDirectJoinBundle.brandableEncodedLength),
    );
  });

  test('rejects bytes appended after the roster', () {
    final encoded = _fixture().encode();
    final bytes =
        base64Url
            .decode(base64Url.normalize(encoded.substring('tark-room:'.length)))
            .toList()
          ..add(0);

    expect(
      () => RoomDirectJoinBundle.decode(
        'tark-room:${base64Url.encode(bytes).replaceAll('=', '')}',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a truncated payload', () {
    final encoded = _fixture().encode();

    expect(
      () =>
          RoomDirectJoinBundle.decode(encoded.substring(0, encoded.length - 8)),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a certificate that disagrees with the envelope', () {
    final bundle = _fixture();

    expect(
      () => RoomDirectJoinBundle(
        memberId: bundle.memberId,
        snapshot: bundle.snapshot,
        memberKeyPair: bundle.memberKeyPair,
        certificate: RoomMemberTransportCertificate(
          roomId: const RoomId('cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'),
          memberId: bundle.memberId,
          memberPublicKey: bundle.memberKeyPair.publicKey,
          issuerPublicKey: bundle.certificate.issuerPublicKey,
          issuerSignature: bundle.certificate.issuerSignature,
        ),
        expiresAt: bundle.expiresAt,
      ).encode(),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects an expired invite on the way in', () {
    final encoded = _fixture(
      expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    ).encode();

    expect(
      () => RoomDirectJoinBundle.decode(encoded),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects a code that is not an invite at all', () {
    expect(
      () => RoomDirectJoinBundle.decode('WIFI:S:somewhere;T:WPA;P:hunter2;;'),
      throwsA(isA<FormatException>()),
    );
  });
}

const _roomId = RoomId('abababababababababababababababab');
const _ownerId = RoomMemberId('111111111111111111111111');
const _joinerId = RoomMemberId('222222222222222222222222');
final _createdAt = DateTime.utc(2026, 9, 2, 12, 30, 15, 250);

List<int> _filled(int length, int seed) =>
    List<int>.generate(length, (i) => (i * 7 + seed) & 0xff, growable: false);

RoomDirectJoinBundle _fixture({int extraMembers = 0, DateTime? expiresAt}) {
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: _filled(32, 3),
    publicKey: _filled(32, 11),
  );
  return RoomDirectJoinBundle(
    memberId: _joinerId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: _roomId,
      roomName: 'Morning ride',
      roomCreatedAt: _createdAt,
      roomUpdatedAt: _createdAt.add(const Duration(minutes: 5)),
      members: [
        RoomAcceptedJoinMember(
          memberId: _ownerId,
          displayName: 'همراه اول',
          joinedAt: _createdAt,
          kind: RoomMemberKind.member,
        ),
        for (var index = 0; index < extraMembers; index += 1)
          RoomAcceptedJoinMember(
            memberId: RoomMemberId(
              '3333333333333333333333${index ~/ 10}'
              '${index % 10}',
            ),
            displayName: 'همراه شماره $index',
            joinedAt: _createdAt,
            kind: RoomMemberKind.member,
          ),
        RoomAcceptedJoinMember(
          memberId: _joinerId,
          displayName: 'Open seat',
          joinedAt: _createdAt,
          kind: RoomMemberKind.guest,
        ),
      ],
      grantsInviteManagement: true,
    ),
    memberKeyPair: keyPair,
    certificate: RoomMemberTransportCertificate(
      roomId: _roomId,
      memberId: _joinerId,
      memberPublicKey: keyPair.publicKey,
      issuerPublicKey: _filled(32, 29),
      issuerSignature: _filled(64, 47),
    ),
    expiresAt: expiresAt ?? DateTime.utc(2099),
  );
}

/// The envelope builds before this one wrote: base64url over JSON whose
/// `snapshot` and `certificate` are themselves base64url strings, so their
/// bytes paid the 4/3 expansion twice.
///
/// Written out here rather than kept behind a flag in the encoder, because the
/// app must never mint one again — only read one.
String _encodeAsV1(RoomDirectJoinBundle bundle) {
  final json = jsonEncode({
    'v': RoomDirectJoinBundle.legacyVersion,
    'memberId': bundle.memberId.value,
    'snapshot': bundle.snapshot.encode(),
    'privateKey': bundle.memberKeyPair.encodedPrivateKey,
    'publicKey': bundle.memberKeyPair.encodedPublicKey,
    'certificate': bundle.certificate.encode(),
    'expiresAt': bundle.expiresAt.toUtc().toIso8601String(),
  });
  return 'tark-room:${base64Url.encode(utf8.encode(json)).replaceAll('=', '')}';
}
