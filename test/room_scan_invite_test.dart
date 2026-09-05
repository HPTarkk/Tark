import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/entity/room_scan_invite.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  test('legacy/direct Room invite remains byte-for-byte unchanged', () {
    final bundle = _fixture();
    final direct = bundle.encode();
    final invite = RoomScanInvite(bundle: bundle);

    expect(invite.encode(), direct);
    final decoded = RoomScanInvite.decode(direct);
    expect(decoded.bundle.memberId, bundle.memberId);
    expect(decoded.transportBootstrap, isNull);
  });

  test('one-scan envelope round-trips membership and transport bootstrap', () {
    final bundle = _fixture();
    const bootstrap = 'WIFI:S:Tark-Ride;T:WPA;P:secret123;;';
    final encoded = RoomScanInvite(
      bundle: bundle,
      transportBootstrap: bootstrap,
    ).encode();

    expect(encoded, startsWith('tark-room-auto:'));
    expect(encoded, isNot(contains(bootstrap)));
    expect(encoded, isNot(contains('secret123')));

    final decoded = RoomScanInvite.decode(encoded);
    expect(decoded.bundle.memberId, bundle.memberId);
    expect(decoded.bundle.snapshot.roomId, bundle.snapshot.roomId);
    expect(decoded.transportBootstrap, bootstrap);
  });

  test('one-scan scheme is classified as our invite when malformed', () {
    expect(RoomScanInvite.looksLikeInvite('tark-room-auto:broken.payload'), isTrue);
    expect(
      () => RoomScanInvite.decode('tark-room-auto:broken.payload'),
      throwsA(isA<FormatException>()),
    );
  });

  test('empty or ambiguous transport field fails closed', () {
    final directBody = _fixture().encode().substring('tark-room:'.length);
    expect(
      () => RoomScanInvite.decode('tark-room-auto:$directBody.'),
      throwsA(isA<FormatException>()),
    );
    final bootstrap = base64Url.encode(utf8.encode('wifi')).replaceAll('=', '');
    expect(
      () => RoomScanInvite.decode(
        'tark-room-auto:$directBody.$bootstrap.trailing',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

const _roomId = RoomId('abababababababababababababababab');
const _ownerId = RoomMemberId('111111111111111111111111');
const _joinerId = RoomMemberId('222222222222222222222222');
final _createdAt = DateTime.utc(2026, 9, 5, 1, 0);

List<int> _filled(int length, int seed) =>
    List<int>.generate(length, (i) => (i * 7 + seed) & 0xff, growable: false);

RoomDirectJoinBundle _fixture() {
  final keyPair = RoomMemberTransportKeyPair(
    privateKey: _filled(32, 3),
    publicKey: _filled(32, 11),
  );
  return RoomDirectJoinBundle(
    memberId: _joinerId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: _roomId,
      roomName: 'Ride',
      roomCreatedAt: _createdAt,
      roomUpdatedAt: _createdAt,
      members: [
        RoomAcceptedJoinMember(
          memberId: _ownerId,
          displayName: 'Host',
          joinedAt: _createdAt,
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: _joinerId,
          displayName: 'Open seat',
          joinedAt: _createdAt,
          kind: RoomMemberKind.member,
        ),
      ],
      grantsInviteManagement: false,
    ),
    memberKeyPair: keyPair,
    certificate: RoomMemberTransportCertificate(
      roomId: _roomId,
      memberId: _joinerId,
      memberPublicKey: keyPair.publicKey,
      issuerPublicKey: _filled(32, 29),
      issuerSignature: _filled(64, 47),
    ),
    expiresAt: DateTime.utc(2099),
  );
}
