import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/presentation/widget/room_connection_status_scope.dart';

void main() {
  group('verified Room speaking presence', () {
    test('only a current-generation proven member exposes its live sender', () {
      final fixture = _fixture();
      final generation = fixture.liveSession.attachment.generation;
      final status = RoomConnectionStatusData(
        room: fixture.room,
        session: fixture.liveSession,
        proofGenerationByMember: {fixture.provenMember.id: generation},
        transportSenderIdByMember: {
          fixture.provenMember.id: 'transport-ali-a',
          // Deliberately present as untrusted metadata. Without a matching
          // current-generation proof this must never become roster presence.
          fixture.unprovenSameNameMember.id: 'transport-ali-b',
        },
      );

      expect(
        status.transportSenderIdFor(fixture.provenMember),
        'transport-ali-a',
      );
      expect(
        status.transportSenderIdFor(fixture.unprovenSameNameMember),
        isNull,
      );
    });

    test('sender metadata is rejected after attachment generation changes', () {
      final fixture = _fixture();
      final currentGeneration = fixture.liveSession.attachment.generation;
      final status = RoomConnectionStatusData(
        room: fixture.room,
        session: fixture.liveSession,
        proofGenerationByMember: {
          fixture.provenMember.id: currentGeneration - 1,
        },
        transportSenderIdByMember: {
          fixture.provenMember.id: 'stale-transport-sender',
        },
      );

      expect(status.transportSenderIdFor(fixture.provenMember), isNull);
    });

    test('durable roster keeps TX updates row-scoped', () {
      final source = File(
        'lib/feature/walkie/presentation/widget/user_list.dart',
      ).readAsStringSync();

      expect(source, contains('class _RoomMemberPresenceTile'));
      expect(
        source,
        contains(
          'BlocSelector<WalkieTalkieCubit, WalkieTalkieState, bool>',
        ),
      );
      expect(source, contains('if (user.id == senderId) return user.isTalking;'));
      expect(
        source,
        contains('previous.connectionHealth != current.connectionHealth'),
      );
      expect(
        source,
        isNot(contains('user.name == member.displayName')),
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
  final attaching = RoomSession.open(
    roomId: room.room.id.value,
    sessionId: 'session',
    localMemberId: localId.value,
    memberIds: [provenId.value, unprovenId.value],
  ).startAttachment(kind: TransportKind.wifi);
  final liveSession = attaching.attachmentReady(
    generation: attaching.attachment.generation,
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
