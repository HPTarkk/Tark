import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_invitation_ledger.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_exchange.dart';
import 'package:tark/feature/room/domain/service/room_invite_join_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';

void main() {
  test('two-phone smoke: one QR scan persists and selects the same Room', () async {
    final ownerRoomId = const RoomId('abababababababababababababababab');
    final ownerId = const RoomMemberId('111111111111111111111111');
    final joinerId = const RoomMemberId('222222222222222222222222');
    final now = DateTime.now().toUtc();
    final crypto = RoomMemberTransportIdentityCrypto();
    final issuer = await crypto.generateKeyPair();
    final joinerKeys = await crypto.generateKeyPair();
    final certificate = await crypto.issueCertificate(
      roomId: ownerRoomId,
      memberId: joinerId,
      memberPublicKey: joinerKeys.publicKey,
      issuer: issuer,
    );
    final snapshot = RoomAcceptedJoinSnapshot(
      roomId: ownerRoomId,
      roomName: 'Morning ride',
      roomCreatedAt: now,
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: ownerId,
          displayName: 'Owner phone',
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
        RoomAcceptedJoinMember(
          memberId: joinerId,
          displayName: 'Joiner phone',
          joinedAt: now,
          kind: RoomMemberKind.member,
        ),
      ],
    );
    final qr = RoomDirectJoinBundle(
      memberId: joinerId,
      snapshot: snapshot,
      memberKeyPair: joinerKeys,
      certificate: certificate,
      expiresAt: now.add(const Duration(hours: 12)),
    ).encode();

    final joinerRepository = _JoinRepository();
    final identityStore = _MemoryIdentityStore();
    final joinerPhone = RoomListCubit(
      joinerRepository,
      identityStore: identityStore,
    );
    final joined = await joinerPhone.joinDirect(RoomDirectJoinBundle.decode(qr));

    expect(joined, isTrue);
    expect(joinerPhone.state.selectedRoomId, ownerRoomId);
    expect(joinerPhone.state.selectedRoom!.room.name, 'Morning ride');
    expect(joinerPhone.state.selectedRoom!.membership.localMemberId, joinerId);
    expect(identityStore.writeCount, 1);
    expect(qr, startsWith('tark-room:'));
    await joinerPhone.close();
  });

  test(
    'verified carrier grant is persisted and selected by RoomListCubit',
    () async {
      final repository = _JoinRepository();
      final identityStore = _MemoryIdentityStore();
      final cubit = RoomListCubit(repository, identityStore: identityStore);
      final crypto = RoomMemberTransportIdentityCrypto();
      final issuer = await crypto.generateKeyPair();
      final now = DateTime.utc(2026, 8, 26, 18);
      final invitation = generateRoomInvitation(
        roomId: const RoomId('11111111111111111111111111111111'),
        kind: RoomInvitationKind.trustedMembership,
        now: now,
        ttl: const Duration(hours: 1),
      );

      final status = await cubit.joinByInvite(
        invitation: invitation,
        displayName: 'Joined rider',
        carrier: _Carrier((encodedRequest) async {
          final request = RoomInviteJoinRequest.decode(encodedRequest);
          final memberId = RoomMemberId(
            request.invitation.invitationId.substring(0, 24),
          );
          final memberPublicKey = request.memberTransportPublicKey!;
          final certificate = await crypto.issueCertificate(
            roomId: request.invitation.roomId,
            memberId: memberId,
            memberPublicKey: memberPublicKey,
            issuer: issuer,
          );
          return RoomInviteJoinResponse.accepted(
            requestId: request.requestId,
            roomId: request.invitation.roomId,
            memberId: memberId,
            snapshot: RoomAcceptedJoinSnapshot(
              roomId: request.invitation.roomId,
              roomName: 'Night riders',
              roomCreatedAt: now.subtract(const Duration(days: 1)),
              roomUpdatedAt: now,
              members: [
                RoomAcceptedJoinMember(
                  memberId: const RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa'),
                  displayName: 'Owner',
                  joinedAt: now.subtract(const Duration(days: 1)),
                  kind: RoomMemberKind.member,
                ),
                RoomAcceptedJoinMember(
                  memberId: memberId,
                  displayName: request.displayName,
                  joinedAt: now,
                  kind: RoomMemberKind.member,
                ),
              ],
            ),
            transportCertificate: certificate,
          ).encode();
        }),
      );

      expect(status, RoomInviteJoinAttemptStatus.accepted);
      expect(repository.imports, 1);
      expect(repository.selected, invitation.roomId);
      expect(cubit.state.selectedRoomId, invitation.roomId);
      expect(cubit.state.rooms.single.room.name, 'Night riders');
      expect(identityStore.writeCount, 1);
      await cubit.close();
    },
  );

  test(
    'invalid carrier response leaves durable Room state untouched',
    () async {
      final repository = _JoinRepository();
      final cubit = RoomListCubit(
        repository,
        identityStore: _MemoryIdentityStore(),
      );
      final now = DateTime.utc(2026, 8, 26, 18);
      final invitation = generateRoomInvitation(
        roomId: const RoomId('22222222222222222222222222222222'),
        kind: RoomInvitationKind.trustedMembership,
        now: now,
        ttl: const Duration(hours: 1),
      );

      final status = await cubit.joinByInvite(
        invitation: invitation,
        displayName: 'Joined rider',
        carrier: const _Carrier.invalid(),
      );

      expect(status, RoomInviteJoinAttemptStatus.invalidResponse);
      expect(repository.imports, 0);
      expect(repository.selected, isNull);
      expect(cubit.state.rooms, isEmpty);
      await cubit.close();
    },
  );
}

final class _MemoryIdentityStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};
  var writeCount = 0;

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    _values.remove(_key(roomId, memberId));
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

final class _Carrier implements RoomInviteJoinCarrier {
  const _Carrier(this._exchange);
  const _Carrier.invalid() : _exchange = _invalid;

  final Future<String> Function(String encodedRequest) _exchange;

  static Future<String> _invalid(String _) async => '{not-valid-json';

  @override
  Future<String> exchange(String encodedRequest) => _exchange(encodedRequest);
}

final class _JoinRepository implements RoomRepository {
  final List<SavedRoom> _rooms = [];
  RoomId? selected;
  int imports = 0;

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async =>
      List.unmodifiable(_rooms);

  @override
  Future<SavedRoom?> get(RoomId id) async {
    for (final room in _rooms) {
      if (room.room.id == id) return room;
    }
    return null;
  }

  @override
  Future<SavedRoom> importAcceptedJoin(
    RoomAcceptedJoinSnapshot snapshot, {
    required RoomMemberId localMemberId,
  }) async {
    imports += 1;
    final saved = SavedRoom(
      room: Room(
        id: snapshot.roomId,
        name: snapshot.roomName,
        createdAt: snapshot.roomCreatedAt,
        updatedAt: snapshot.roomUpdatedAt,
        members: snapshot.members
            .map(
              (member) => RoomMember(
                id: member.memberId,
                displayName: member.displayName,
                joinedAt: member.joinedAt,
                kind: member.kind,
              ),
            )
            .toList(growable: false),
      ),
      membership: RoomMembership(
        localMemberId: localMemberId,
        canManageInvites: false,
      ),
    );
    _rooms
      ..removeWhere((room) => room.room.id == snapshot.roomId)
      ..add(saved);
    return saved;
  }

  @override
  Future<RoomId?> selectedRoomId() async => selected;

  @override
  Future<void> select(RoomId? id) async {
    selected = id;
  }

  @override
  Future<SavedRoom> create({
    required String name,
    required String localDisplayName,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> rename(RoomId id, String name) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> setArchived(RoomId id, bool archived) =>
      throw UnimplementedError();

  @override
  Future<RoomInvitation> issueInvite(
    RoomId id, {
    required RoomInvitationKind kind,
    required DateTime now,
    required Duration ttl,
    RoomTransportBootstrap? transportBootstrap,
  }) => throw UnimplementedError();

  @override
  Future<VerifiedRoomInvitation?> verifyAndRedeemInvite(
    RoomInvitation invite, {
    required DateTime now,
  }) => throw UnimplementedError();

  @override
  Future<void> revokeInvite(RoomInvitation invite) =>
      throw UnimplementedError();

  @override
  Future<SavedRoom> acceptVerifiedInvite(
    VerifiedRoomInvitation verified, {
    required String displayName,
    required DateTime acceptedAt,
  }) => throw UnimplementedError();

  @override
  Future<SavedRoom> leave(RoomId id) => throw UnimplementedError();

  @override
  Future<void> delete(RoomId id) => throw UnimplementedError();
}
