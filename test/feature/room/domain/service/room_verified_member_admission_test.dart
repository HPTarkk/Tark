import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_proof_binding_authority.dart';
import 'package:tark/feature/room/domain/service/room_peer_member_binding_registry.dart';

/// ITEM 10 (c): a member invited by somebody else reaches this phone only as a
/// live route proof. It is admitted on exactly the evidence the joining phone
/// itself checked — a certificate chain back to the Room key — and never on
/// anything less.
void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const hostId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa00');
  const delegateId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa01');
  const newcomerId = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaa02');
  final at = DateTime.utc(2026, 10, 1, 8);

  late RoomMemberTransportKeyPair root;
  late RoomMemberTransportKeyPair delegate;
  late RoomMemberTransportKeyPair newcomer;

  setUpAll(() async {
    root = await crypto.generateKeyPair();
    delegate = await crypto.generateKeyPair();
    newcomer = await crypto.generateKeyPair();
  });

  Future<RoomMemberTransportCertificate> newcomerCertificate({
    required bool delegateGranted,
  }) async {
    final delegateCert = await crypto.issueCertificate(
      roomId: roomId,
      memberId: delegateId,
      memberPublicKey: delegate.publicKey,
      issuer: root,
      grantInvite: delegateGranted,
    );
    if (delegateGranted) {
      return crypto.issueCertificate(
        roomId: roomId,
        memberId: newcomerId,
        memberPublicKey: newcomer.publicKey,
        issuer: delegate,
        issuerCertificate: delegateCert,
      );
    }
    // What a member without the right would have to produce: its own
    // signature, its own (ungranted) certificate as the link.
    final signed = await crypto.issueCertificate(
      roomId: roomId,
      memberId: newcomerId,
      memberPublicKey: newcomer.publicKey,
      issuer: delegate,
    );
    return RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: newcomerId,
      memberPublicKey: newcomer.publicKey,
      issuerPublicKey: delegate.publicKey,
      issuerSignature: signed.issuerSignature,
      issuerChain: [
        RoomInviteDelegation(
          memberId: delegateId,
          memberPublicKey: delegate.publicKey,
          issuerSignature: delegateCert.issuerSignature,
          inviteGrant: List.filled(64, 3),
        ),
      ],
      chainRootPublicKey: root.publicKey,
    );
  }

  Future<ProvenRoomMember?> present(
    RoomMemberTransportProofBindingAuthority authority,
    RoomMemberTransportCertificate certificate,
  ) async {
    authority.observeChallenge(
      peerKey: 'udp:10.0.0.9:4000',
      token: 77,
      sessionEpoch: 5,
      attachmentGeneration: 1,
      at: at,
    );
    final name = await crypto.signMemberName(
      certificate: certificate,
      member: newcomer,
      name: 'Sara',
    );
    final proof = await crypto.signProof(
      certificate: certificate,
      member: newcomer,
      token: 77,
      sessionEpoch: 5,
      name: name,
    );
    return authority.verifyAndBind(
      peerKey: 'udp:10.0.0.9:4000',
      encodedProof: proof.encode(),
      attachmentGeneration: 1,
      at: at,
    );
  }

  test('a delegate\'s invitee is admitted once its chain verifies', () async {
    final admitted = <(RoomMemberId, String?)>[];
    final bindings = RoomPeerMemberBindingRegistry(members: const [hostId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: root.publicKey,
      admitVerifiedMember: (certificate, name) async {
        admitted.add((certificate.memberId, name));
        return true;
      },
    );

    final proven = await present(
      authority,
      await newcomerCertificate(delegateGranted: true),
    );

    expect(proven?.memberId, newcomerId);
    expect(proven?.displayName, 'Sara');
    expect(admitted, [(newcomerId, 'Sara')]);
    expect(bindings.contains(newcomerId), isTrue);
  });

  test(
    'a stranger signed by an ungranted member is never even asked about',
    () async {
      var asked = false;
      final bindings = RoomPeerMemberBindingRegistry(members: const [hostId]);
      final authority = RoomMemberTransportProofBindingAuthority(
        roomId: roomId,
        bindings: bindings,
        expectedIssuerPublicKey: root.publicKey,
        admitVerifiedMember: (_, _) async => asked = true,
      );

      final proven = await present(
        authority,
        await newcomerCertificate(delegateGranted: false),
      );

      expect(proven, isNull);
      expect(asked, isFalse);
      expect(bindings.contains(newcomerId), isFalse);
    },
  );

  test('the roster still has the last word', () async {
    final bindings = RoomPeerMemberBindingRegistry(members: const [hostId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: root.publicKey,
      admitVerifiedMember: (_, _) async => false,
    );

    expect(
      await present(
        authority,
        await newcomerCertificate(delegateGranted: true),
      ),
      isNull,
    );
    expect(bindings.contains(newcomerId), isFalse);
  });

  test('without an admitter the original rule stands', () async {
    final bindings = RoomPeerMemberBindingRegistry(members: const [hostId]);
    final authority = RoomMemberTransportProofBindingAuthority(
      roomId: roomId,
      bindings: bindings,
      expectedIssuerPublicKey: root.publicKey,
    );

    expect(
      await present(
        authority,
        await newcomerCertificate(delegateGranted: true),
      ),
      isNull,
    );
  });

  group('durable admission', () {
    late SharedPreferencesRoomRepository repository;
    late SavedRoom room;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      repository = SharedPreferencesRoomRepository();
      room = await repository.create(name: 'Ride', localDisplayName: 'Host');
    });

    test(
      'an unknown member is added, confirmed, under their signed name',
      () async {
        expect(
          await repository.admitVerifiedMember(
            room.room.id,
            newcomerId,
            displayName: 'Sara',
            at: at,
          ),
          isTrue,
        );
        final saved = await repository.get(room.room.id);
        final row = saved!.room.members.singleWhere((m) => m.id == newcomerId);
        expect(row.displayName, 'Sara');
        expect(row.pending, isFalse);
        expect(saved.room.confirmedMembers, hasLength(2));
      },
    );

    test('without a name the row takes the placeholder a later proof may '
        'replace', () async {
      await repository.admitVerifiedMember(room.room.id, newcomerId, at: at);
      final saved = await repository.get(room.room.id);
      final row = saved!.room.members.singleWhere((m) => m.id == newcomerId);
      expect(row.displayName, 'Open seat');
    });

    test(
      'an already active member is accepted and nothing is written',
      () async {
        await repository.admitVerifiedMember(room.room.id, newcomerId, at: at);
        final before = await repository.get(room.room.id);
        expect(
          await repository.admitVerifiedMember(
            room.room.id,
            newcomerId,
            displayName: 'Other',
            at: at.add(const Duration(minutes: 1)),
          ),
          isTrue,
        );
        final after = await repository.get(room.room.id);
        expect(after!.room.updatedAt, before!.room.updatedAt);
        expect(after.room.members, hasLength(2));
      },
    );

    test('a member removed on this phone stays removed', () async {
      await repository.admitVerifiedMember(room.room.id, newcomerId, at: at);
      await repository.removeMember(room.room.id, newcomerId);

      expect(
        await repository.admitVerifiedMember(room.room.id, newcomerId, at: at),
        isFalse,
      );
      final saved = await repository.get(room.room.id);
      expect(
        saved!.room.members.singleWhere((m) => m.id == newcomerId).isActive,
        isFalse,
      );
    });
  });
}
