import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/presentation/widget/room_connection_status_scope.dart';
import 'package:tark/feature/walkie/presentation/widget/user_list.dart';

void main() {
  group('verified Room roster identity', () {
    test('same display name cannot connect the wrong durable member', () {
      final fixture = _fixture();
      final status = RoomConnectionStatusData(
        room: fixture.room,
        session: fixture.liveSession,
        proofGenerationByMember: {
          fixture.provenMember.id: fixture.liveSession.attachment.generation,
        },
      );

      expect(
        roomRosterMemberPhase(
          room: fixture.room,
          member: fixture.unprovenSameNameMember,
          verifiedStatus: status,
          transportLive: true,
          startFailed: false,
        ),
        RoomConnectionUiPhase.connecting,
      );
      expect(
        roomRosterMemberPhase(
          room: fixture.room,
          member: fixture.provenMember,
          verifiedStatus: status,
          transportLive: true,
          startFailed: false,
        ),
        RoomConnectionUiPhase.connected,
      );
    });

    test(
      'live transport without verified Room scope never means connected',
      () {
        final fixture = _fixture();

        expect(
          roomRosterMemberPhase(
            room: fixture.room,
            member: fixture.provenMember,
            verifiedStatus: null,
            transportLive: true,
            startFailed: false,
          ),
          RoomConnectionUiPhase.connecting,
        );
      },
    );

    test('proof from a stale attachment generation is not connected', () {
      final fixture = _fixture();
      final status = RoomConnectionStatusData(
        room: fixture.room,
        session: fixture.liveSession,
        proofGenerationByMember: {fixture.provenMember.id: 0},
      );

      expect(
        roomRosterMemberPhase(
          room: fixture.room,
          member: fixture.provenMember,
          verifiedStatus: status,
          transportLive: true,
          startFailed: false,
        ),
        RoomConnectionUiPhase.connecting,
      );
    });
  });
}

_Fixture _fixture() {
  final joinedAt = DateTime.utc(2026, 9, 8);
  const localId = RoomMemberId('local-member');
  const provenId = RoomMemberId('proven-member');
  const unprovenId = RoomMemberId('unproven-member');
  final local = RoomMember(
    id: localId,
    displayName: 'Rider',
    joinedAt: joinedAt,
  );
  final proven = RoomMember(
    id: provenId,
    displayName: 'Ali',
    joinedAt: joinedAt.add(const Duration(seconds: 1)),
  );
  final unproven = RoomMember(
    id: unprovenId,
    displayName: 'Ali',
    joinedAt: joinedAt.add(const Duration(seconds: 2)),
  );
  final room = SavedRoom(
    room: Room(
      id: const RoomId('room-id'),
      name: 'Ride',
      createdAt: joinedAt,
      updatedAt: joinedAt,
      members: [local, proven, unproven],
    ),
    membership: const RoomMembership(
      localMemberId: localId,
      canManageInvites: true,
    ),
  );
  final live = RoomSession.open(
    roomId: room.room.id.value,
    sessionId: 'session',
    localMemberId: localId.value,
    memberIds: [provenId.value, unprovenId.value],
  ).startAttachment(kind: TransportKind.wifi);
  final liveSession = live.attachmentReady(
    generation: live.attachment.generation,
  );

  return _Fixture(
    room: room,
    provenMember: proven,
    unprovenSameNameMember: unproven,
    liveSession: liveSession,
  );
}

class _Fixture {
  const _Fixture({
    required this.room,
    required this.provenMember,
    required this.unprovenSameNameMember,
    required this.liveSession,
  });

  final SavedRoom room;
  final RoomMember provenMember;
  final RoomMember unprovenSameNameMember;
  final RoomSession liveSession;
}
