import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

void main() {
  final roomId = RoomId('a' * 32);
  const ownerId = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');
  const riderId = RoomMemberId('cccccccccccccccccccccccc');
  final now = DateTime.utc(2026, 8, 27);

  SavedRoom saved({
    RoomMemberId memberId = ownerId,
    bool canManageInvites = true,
  }) => SavedRoom(
    room: Room(
      id: roomId,
      name: 'Ride',
      createdAt: now,
      updatedAt: now,
      members: [
        RoomMember(id: memberId, displayName: 'Rider', joinedAt: now),
      ],
    ),
    membership: RoomMembership(
      localMemberId: memberId,
      canManageInvites: canManageInvites,
    ),
  );

  test('owner identity is provisioned once and then reused', () async {
    final store = _MemoryStore();
    final lifecycle = RoomTransportIdentityLifecycle(store: store);
    final owner = saved();

    final first = await lifecycle.ensureLocalIdentity(owner);
    final second = await lifecycle.ensureLocalIdentity(owner);

    expect(first.issuerKeyPair, isNotNull);
    expect(second.memberKeyPair.privateKey, first.memberKeyPair.privateKey);
    expect(second.certificate.encode(), first.certificate.encode());
    expect(store.writeCount, 1);
  });

  test('ordinary member missing secure identity fails closed', () async {
    final lifecycle = RoomTransportIdentityLifecycle(store: _MemoryStore());

    await expectLater(
      lifecycle.ensureLocalIdentity(
        saved(memberId: riderId, canManageInvites: false),
      ),
      throwsStateError,
    );
  });

  test('issuer certificate binds accepted member public key', () async {
    final lifecycle = RoomTransportIdentityLifecycle(store: _MemoryStore());
    final crypto = RoomMemberTransportIdentityCrypto();
    final member = await crypto.generateKeyPair();

    final certificate = await lifecycle.issueMemberCertificate(
      issuerRoom: saved(),
      memberId: riderId,
      memberPublicKey: member.publicKey,
    );

    expect(certificate.roomId, roomId);
    expect(certificate.memberId, riderId);
    expect(certificate.memberPublicKey, member.publicKey);
    expect(
      await crypto.verifyCertificate(
        certificate: certificate,
        expectedIssuerPublicKey: certificate.issuerPublicKey,
      ),
      isTrue,
    );
  });

  test('joined identity rejects a certificate for another public key', () async {
    final store = _MemoryStore();
    final lifecycle = RoomTransportIdentityLifecycle(store: store);
    final crypto = RoomMemberTransportIdentityCrypto();
    final issuer = await crypto.generateKeyPair();
    final member = await crypto.generateKeyPair();
    final attacker = await crypto.generateKeyPair();
    final joined = saved(memberId: riderId, canManageInvites: false);
    final wrongCertificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: riderId,
      memberPublicKey: attacker.publicKey,
      issuer: issuer,
    );

    await expectLater(
      lifecycle.persistJoinedIdentity(
        saved: joined,
        memberKeyPair: member,
        certificate: wrongCertificate,
      ),
      throwsFormatException,
    );
    expect(store.writeCount, 0);
  });

  test('delete removes only the local Room member identity scope', () async {
    final store = _MemoryStore();
    final lifecycle = RoomTransportIdentityLifecycle(store: store);
    final owner = saved();
    await lifecycle.ensureLocalIdentity(owner);

    await lifecycle.deleteLocalIdentity(owner);

    expect(await lifecycle.readLocalIdentity(owner), isNull);
    expect(store.deletedScopes, [(roomId.value, ownerId.value)]);
  });
}

final class _MemoryStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};
  final List<(String, String)> deletedScopes = [];
  int writeCount = 0;

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({required RoomId roomId, required RoomMemberId memberId}) async {
    _values.remove(_key(roomId, memberId));
    deletedScopes.add((roomId.value, memberId.value));
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values[_key(roomId, memberId)];

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    writeCount += 1;
    _values[_key(roomId, memberId)] = material;
  }
}
