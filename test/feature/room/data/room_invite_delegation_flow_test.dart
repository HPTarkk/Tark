import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_client.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_importer.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';

/// ITEM 10 end to end, one phone at a time: what the creator signs, what a
/// joiner may then do with it, and what nobody can do by editing bytes.
///
/// SharedPreferences is process-global in tests, so each "phone" gets a fresh
/// store in turn and only the QR string crosses between them — exactly what
/// crosses between real phones.
void main() {
  final crypto = RoomMemberTransportIdentityCrypto();

  /// The joiner's side of a scan: decode, then the same import the cubit runs.
  Future<SavedRoom> scan(
    String code,
    RoomTransportIdentityLifecycle identity,
  ) async {
    final repository = SharedPreferencesRoomRepository();
    final bundle = RoomDirectJoinBundle.decode(code);
    final importer = RoomInviteJoinImporter(
      repository: repository,
      persistTransportIdentity: identity.persistJoinedIdentity,
    );
    return importer.importGrant(
      RoomInviteJoinGrant(
        roomId: bundle.snapshot.roomId,
        memberId: bundle.memberId,
        displayName: 'Rider',
        snapshot: bundle.snapshot,
        transportCertificate: bundle.certificate,
      ),
      memberKeyPair: bundle.memberKeyPair,
    );
  }

  /// What the invite sheet does on the issuing phone.
  Future<String> invite(
    SavedRoom issuer,
    RoomTransportIdentityLifecycle identity, {
    required bool grant,
  }) async {
    final repository = SharedPreferencesRoomRepository();
    final now = DateTime.now().toUtc();
    final issued = await repository.issueInvite(
      issuer.room.id,
      kind: RoomInvitationKind.trustedMembership,
      now: now,
      ttl: const Duration(hours: 12),
    );
    final verified = await repository.verifyAndRedeemInvite(issued, now: now);
    final accepted = await repository.acceptVerifiedInvite(
      verified!,
      displayName: 'Open seat',
      acceptedAt: now,
      pending: true,
      heldUntil: issued.expiresAt,
    );
    final memberId = RoomMemberId(issued.invitationId.substring(0, 24));
    final keyPair = await identity.createPendingMemberKeyPair();
    final certificate = await identity.issueMemberCertificate(
      issuerRoom: accepted,
      memberId: memberId,
      memberPublicKey: keyPair.publicKey,
      grantInvite: grant,
    );
    return RoomDirectJoinBundle(
      memberId: memberId,
      snapshot: RoomAcceptedJoinSnapshot.fromSavedRoom(
        accepted,
        acceptedMemberId: memberId,
        grantsInviteManagement: certificate.canInvite,
      ),
      memberKeyPair: keyPair,
      certificate: certificate,
      expiresAt: issued.expiresAt,
    ).encode();
  }

  late _MemoryStore creatorStore;
  late RoomTransportIdentityLifecycle creatorIdentity;
  late SavedRoom created;
  late List<int> rootKey;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    creatorStore = _MemoryStore();
    creatorIdentity = RoomTransportIdentityLifecycle(store: creatorStore);
    created = await SharedPreferencesRoomRepository().create(
      name: 'Night ride',
      localDisplayName: 'Host',
    );
    rootKey = (await creatorIdentity.ensureLocalIdentity(
      created,
    )).certificate.rootIssuerPublicKey;
  });

  test('the creator always can invite and grant', () async {
    expect(created.membership.canManageInvites, isTrue);
    expect(created.membership.ownsRoomKey, isTrue);
    expect(await creatorIdentity.canGrantInvites(created), isTrue);
  });

  test('a granted joiner can invite, and its invitee is accepted by the '
      'creator\'s key', () async {
    final code = await invite(created, creatorIdentity, grant: true);
    expect(_version(code), RoomDirectJoinBundle.delegatedVersion);

    // Phone 2: the granted joiner.
    SharedPreferences.setMockInitialValues({});
    final joinerIdentity = RoomTransportIdentityLifecycle(
      store: _MemoryStore(),
    );
    final joiner = await scan(code, joinerIdentity);
    expect(joiner.membership.canManageInvites, isTrue);
    expect(joiner.membership.ownsRoomKey, isFalse);
    expect(await joinerIdentity.canGrantInvites(joiner), isTrue);

    final onward = await invite(joiner, joinerIdentity, grant: false);

    // Phone 3: the joiner's invitee.
    SharedPreferences.setMockInitialValues({});
    final newcomerIdentity = RoomTransportIdentityLifecycle(
      store: _MemoryStore(),
    );
    final newcomer = await scan(onward, newcomerIdentity);
    expect(newcomer.membership.canManageInvites, isFalse);
    final material = await newcomerIdentity.readLocalIdentity(newcomer);
    final certificate = material!.certificate;
    expect(certificate.issuerChain, hasLength(1));
    expect(certificate.rootIssuerPublicKey, rootKey);

    // And the creator — who never saw this person — verifies them.
    expect(
      await crypto.verifyCertificate(
        certificate: certificate,
        expectedIssuerPublicKey: rootKey,
      ),
      isTrue,
    );
  });

  test(
    'a denied joiner cannot invite, even with its local flag forced',
    () async {
      final code = await invite(created, creatorIdentity, grant: false);
      expect(_version(code), RoomDirectJoinBundle.currentVersion);

      SharedPreferences.setMockInitialValues({});
      final store = _MemoryStore();
      final joinerIdentity = RoomTransportIdentityLifecycle(store: store);
      final joiner = await scan(code, joinerIdentity);
      expect(joiner.membership.canManageInvites, isFalse);

      // The repository refuses to mint an invite at all.
      await expectLater(
        SharedPreferencesRoomRepository().issueInvite(
          joiner.room.id,
          kind: RoomInvitationKind.trustedMembership,
          now: DateTime.now().toUtc(),
          ttl: const Duration(hours: 1),
        ),
        throwsStateError,
      );

      // A modified app that flips its own stored permission still has nothing
      // to sign with: no grant in its certificate, no Room key, and it may not
      // mint a fresh Room key either.
      final forced = joiner.copyWith(
        membership: RoomMembership(
          localMemberId: joiner.membership.localMemberId,
          canManageInvites: true,
          ownsRoomKey: false,
        ),
      );
      final newcomer = await crypto.generateKeyPair();
      await expectLater(
        joinerIdentity.issueMemberCertificate(
          issuerRoom: forced,
          memberId: const RoomMemberId('dddddddddddddddddddddddd'),
          memberPublicKey: newcomer.publicKey,
        ),
        throwsStateError,
      );
      expect(await joinerIdentity.canGrantInvites(forced), isFalse);
      final writes = store.writeCount;
      await store.delete(
        roomId: joiner.room.id,
        memberId: joiner.membership.localMemberId,
      );
      await expectLater(
        joinerIdentity.ensureLocalIdentity(forced),
        throwsStateError,
      );
      expect(store.writeCount, writes);
    },
  );

  test(
    'a delegate with a missing identity never founds a second Room key',
    () async {
      final code = await invite(created, creatorIdentity, grant: true);
      SharedPreferences.setMockInitialValues({});
      final store = _MemoryStore();
      final joinerIdentity = RoomTransportIdentityLifecycle(store: store);
      final joiner = await scan(code, joinerIdentity);
      await store.delete(
        roomId: joiner.room.id,
        memberId: joiner.membership.localMemberId,
      );

      await expectLater(
        joinerIdentity.ensureLocalIdentity(joiner),
        throwsStateError,
      );
      expect(await joinerIdentity.canGrantInvites(joiner), isFalse);
    },
  );

  test('a tampered grant fails the scan and leaves no Room behind', () async {
    final code = await invite(created, creatorIdentity, grant: true);
    final bytes = _bytes(code);
    // v4: version, flags, room 16, member 12, private 32, public 32, root 32,
    // signature 64 — then the grant.
    const grantOffset = 2 + 16 + 12 + 32 + 32 + 32 + 64;
    final tampered = [...bytes]..[grantOffset + 5] ^= 0x40;

    SharedPreferences.setMockInitialValues({});
    final identity = RoomTransportIdentityLifecycle(store: _MemoryStore());
    await expectLater(scan(_code(tampered), identity), throwsFormatException);
    expect(await SharedPreferencesRoomRepository().list(), isEmpty);
  });

  test('a flipped capability flag never yields a usable grant', () async {
    final granted = await invite(created, creatorIdentity, grant: true);
    final plain = await invite(created, creatorIdentity, grant: false);

    // Clearing bit 0 on a granted code shifts every later field.
    final cleared = [..._bytes(granted)]..[1] &= ~0x01;
    expect(
      () => RoomDirectJoinBundle.decode(_code(cleared)),
      throwsFormatException,
    );

    // An unknown flag bit on v4 is refused outright.
    final unknown = [..._bytes(granted)]..[1] |= 0x80;
    expect(
      () => RoomDirectJoinBundle.decode(_code(unknown)),
      throwsFormatException,
    );

    // Setting bit 0 on an ungranted v3 code is exactly what an older build
    // could write: it parses, and grants nothing.
    final raised = [..._bytes(plain)]..[1] |= 0x01;
    final decoded = RoomDirectJoinBundle.decode(_code(raised));
    expect(decoded.snapshot.grantsInviteManagement, isTrue);
    SharedPreferences.setMockInitialValues({});
    final joiner = await scan(
      _code(raised),
      RoomTransportIdentityLifecycle(store: _MemoryStore()),
    );
    expect(joiner.membership.canManageInvites, isFalse);
  });

  test('a v4 code that claims a grant it does not carry is refused', () async {
    final plain = RoomDirectJoinBundle.decode(
      await invite(created, creatorIdentity, grant: false),
    );
    final granted = RoomDirectJoinBundle.decode(
      await invite(created, creatorIdentity, grant: true),
    );
    // A granted certificate under a roster that says "no grant" — the two
    // halves of the code have to agree before anything is written.
    final mismatched = RoomDirectJoinBundle(
      memberId: granted.memberId,
      snapshot: granted.snapshot.withInviteGrant(false),
      memberKeyPair: granted.memberKeyPair,
      certificate: granted.certificate,
      expiresAt: granted.expiresAt,
    );
    expect(mismatched.encode, throwsFormatException);
    expect(plain.certificate.canInvite, isFalse);
  });

  test('a delegate cannot pass on a right it was not given to pass', () async {
    // creator → A (grant) → B (grant) → C: B may invite C but not grant.
    final a = await invite(created, creatorIdentity, grant: true);
    SharedPreferences.setMockInitialValues({});
    final aIdentity = RoomTransportIdentityLifecycle(store: _MemoryStore());
    final aRoom = await scan(a, aIdentity);
    final b = await invite(aRoom, aIdentity, grant: true);

    SharedPreferences.setMockInitialValues({});
    final bIdentity = RoomTransportIdentityLifecycle(store: _MemoryStore());
    final bRoom = await scan(b, bIdentity);
    expect(bRoom.membership.canManageInvites, isTrue);
    expect(await bIdentity.canGrantInvites(bRoom), isFalse);
    await expectLater(invite(bRoom, bIdentity, grant: true), throwsStateError);

    SharedPreferences.setMockInitialValues({});
    // Re-create B's phone state: the failed attempt above reset nothing, but
    // this phone's storage was just cleared for the next scan.
    final bAgain = RoomTransportIdentityLifecycle(store: _MemoryStore());
    final bRoomAgain = await scan(b, bAgain);
    final c = await invite(bRoomAgain, bAgain, grant: false);
    SharedPreferences.setMockInitialValues({});
    final cIdentity = RoomTransportIdentityLifecycle(store: _MemoryStore());
    final cRoom = await scan(c, cIdentity);
    expect(cRoom.membership.canManageInvites, isFalse);
    final cCert = (await cIdentity.readLocalIdentity(cRoom))!.certificate;
    expect(cCert.issuerChain, hasLength(2));
    expect(
      await crypto.verifyCertificate(
        certificate: cCert,
        expectedIssuerPublicKey: rootKey,
      ),
      isTrue,
    );
  });

  test('membership stored by the previous release loads unchanged', () async {
    const roomId = '0123456789abcdef0123456789abcdef';
    String record({required bool canManage}) => jsonEncode({
      'schemaVersion': 1,
      'id': roomId,
      'name': 'Old ride',
      'createdAt': '2026-01-01T00:00:00.000Z',
      'updatedAt': '2026-01-01T00:00:00.000Z',
      'archived': false,
      'members': [
        {
          'id': '111111111111111111111111',
          'displayName': 'Me',
          'joinedAt': '2026-01-01T00:00:00.000Z',
          'kind': 'member',
        },
      ],
      'membership': {
        'localMemberId': '111111111111111111111111',
        'canManageInvites': canManage,
        'active': true,
      },
    });

    for (final canManage in [true, false]) {
      SharedPreferences.setMockInitialValues({
        'rooms.v1.index': [roomId],
        'rooms.v1.room.$roomId': record(canManage: canManage),
      });
      final saved = await SharedPreferencesRoomRepository().get(
        const RoomId(roomId),
      );
      expect(saved, isNotNull);
      expect(saved!.membership.canManageInvites, canManage);
      // A pre-delegation invite manager was always a key holder.
      expect(saved.membership.ownsRoomKey, canManage);
    }
  });
}

int _version(String code) => _bytes(code).first;

List<int> _bytes(String code) =>
    base64Url.decode(base64Url.normalize(code.substring('tark-room:'.length)));

String _code(List<int> bytes) =>
    'tark-room:${base64Url.encode(bytes).replaceAll('=', '')}';

final class _MemoryStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};
  int writeCount = 0;

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values.remove(_key(roomId, memberId));

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
