import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';

void main() {
  tearDown(() => GetIt.instance.reset());
  for (final premium in [false, true]) {
    test(
      'joining a third room checks quota before storage: premium=$premium',
      () async {
        GetIt.instance.registerSingleton<LicenseGate>(_Gate(premium));
        final repository = _Rooms();
        final now = DateTime.utc(2026, 10, 9);
        repository.rooms = [
          for (final digit in ['a', 'b'])
            SavedRoom(
              room: Room(
                id: RoomId(digit * 32),
                name: digit,
                createdAt: now,
                updatedAt: now,
                members: const [],
              ),
              membership: const RoomMembership(
                localMemberId: RoomMemberId('111111111111111111111111'),
                canManageInvites: false,
              ),
            ),
        ];
        final cubit = RoomListCubit(repository);
        await cubit.joinDirect(_bundle(2, pending: false));
        expect(repository.importAttempts, premium ? 1 : 0);
        if (!premium) expect(cubit.state.error, isNull);
        expect(cubit.state.loading, isFalse);
        await cubit.close();
      },
    );
  }
  for (final (count, pending, premium, mayImport) in [
    (3, false, false, false),
    (2, false, false, true),
    (3, true, false, true),
    (3, false, true, true),
  ]) {
    test(
      'group join authorization precedes persistence: $count members, held=$pending, premium=$premium',
      () async {
        GetIt.instance.registerSingleton<LicenseGate>(_Gate(premium));
        final repository = _Rooms();
        final cubit = RoomListCubit(repository);
        await cubit.joinDirect(_bundle(count, pending: pending));
        expect(repository.importAttempts, mayImport ? 1 : 0);
        if (!mayImport) {
          expect(cubit.state.loading, isFalse);
          expect(cubit.state.error, isNull);
        }
        await cubit.close();
      },
    );
  }
}

RoomDirectJoinBundle _bundle(int count, {required bool pending}) {
  const roomId = RoomId('0123456789abcdef0123456789abcdef');
  final memberId = RoomMemberId('111111111111111111111111');
  final now = DateTime.utc(2026, 10, 9);
  final keys = RoomMemberTransportKeyPair(
    privateKey: List.filled(32, 1),
    publicKey: List.filled(32, 2),
  );
  return RoomDirectJoinBundle(
    memberId: memberId,
    memberKeyPair: keys,
    expiresAt: DateTime.utc(2099),
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: 'Group',
      roomCreatedAt: now,
      roomUpdatedAt: now,
      members: [
        for (var i = 0; i < count; i++)
          RoomAcceptedJoinMember(
            memberId: i == 0
                ? memberId
                : RoomMemberId('${i + 1}'.padLeft(24, '0')),
            displayName: 'Person $i',
            joinedAt: now,
            kind: RoomMemberKind.member,
            pending: pending && i == 2,
            heldUntil: pending && i == 2
                ? now.add(const Duration(hours: 1))
                : null,
          ),
      ],
    ),
    certificate: RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: keys.publicKey,
      issuerPublicKey: List.filled(32, 3),
      issuerSignature: List.filled(64, 4),
    ),
  );
}

class _Gate implements LicenseGate {
  _Gate(this.premium);
  final bool premium;
  @override
  bool allows(PremiumFeature feature) => premium;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => const Stream.empty();
}

class _Rooms implements RoomRepository {
  int importAttempts = 0;
  List<SavedRoom> rooms = [];
  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => rooms;
  @override
  Future<SavedRoom?> get(RoomId roomId) async {
    importAttempts++;
    // Fail the storage boundary deliberately: this test concerns access to
    // persistence, not certificate verification or import correctness.
    throw StateError('storage unavailable');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
