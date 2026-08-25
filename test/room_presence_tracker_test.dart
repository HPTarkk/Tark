import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_presence_tracker.dart';

void main() {
  const alice = RoomMemberId('alice');
  const bob = RoomMemberId('bob');
  const carol = RoomMemberId('carol');
  final t0 = DateTime.utc(2026, 8, 25, 10);

  test('inbound alone is not proof the peer can hear us', () {
    final tracker = RoomPresenceTracker();
    tracker.markJoining(alice, attachmentGeneration: 1);
    tracker.observeInbound(alice, at: t0, attachmentGeneration: 1);

    expect(tracker.get(alice)!.state, RoomParticipantState.joining);
    expect(tracker.get(alice)!.hasBidirectionalEvidence, isFalse);
  });

  test(
    'bidirectional evidence promotes one stable member row to connected',
    () {
      final tracker = RoomPresenceTracker();
      tracker.markJoining(alice, attachmentGeneration: 1);
      tracker.observeInbound(alice, at: t0, attachmentGeneration: 1);
      tracker.observeOutboundConfirmation(
        alice,
        at: t0.add(const Duration(milliseconds: 50)),
        attachmentGeneration: 1,
      );

      expect(tracker.get(alice)!.state, RoomParticipantState.connected);
      expect(
        tracker.participants.where((item) => item.memberId == alice),
        hasLength(1),
      );
    },
  );

  test('brief unexpected loss shows reconnecting before unreachable', () {
    final tracker = RoomPresenceTracker(
      reconnectGrace: const Duration(seconds: 10),
    );
    tracker.markJoining(alice, attachmentGeneration: 1);
    tracker.observeInbound(alice, at: t0, attachmentGeneration: 1);
    tracker.observeOutboundConfirmation(alice, at: t0, attachmentGeneration: 1);

    tracker.unexpectedLoss(
      alice,
      at: t0.add(const Duration(seconds: 1)),
      attachmentGeneration: 1,
    );
    tracker.advance(t0.add(const Duration(seconds: 9)));
    expect(tracker.get(alice)!.state, RoomParticipantState.reconnecting);

    tracker.advance(t0.add(const Duration(seconds: 11)));
    expect(tracker.get(alice)!.state, RoomParticipantState.unreachable);
  });

  test(
    'restored peer reuses stable identity and clears reconnect tombstone',
    () {
      final tracker = RoomPresenceTracker();
      tracker.markJoining(alice, attachmentGeneration: 1);
      tracker.observeInbound(alice, at: t0, attachmentGeneration: 1);
      tracker.observeOutboundConfirmation(
        alice,
        at: t0,
        attachmentGeneration: 1,
      );
      tracker.unexpectedLoss(
        alice,
        at: t0.add(const Duration(seconds: 1)),
        attachmentGeneration: 1,
      );

      final restoredAt = t0.add(const Duration(seconds: 2));
      tracker.observeInbound(alice, at: restoredAt, attachmentGeneration: 1);
      tracker.observeOutboundConfirmation(
        alice,
        at: restoredAt,
        attachmentGeneration: 1,
      );

      expect(tracker.get(alice)!.state, RoomParticipantState.connected);
      expect(tracker.get(alice)!.reconnectDeadline, isNull);
      expect(
        tracker.participants.where((item) => item.memberId == alice),
        hasLength(1),
      );
    },
  );

  test(
    'explicit leave is immediate and stale evidence cannot resurrect it',
    () {
      final tracker = RoomPresenceTracker();
      tracker.markJoining(alice, attachmentGeneration: 3);
      tracker.explicitLeave(alice, attachmentGeneration: 3);
      tracker.observeInbound(
        alice,
        at: t0.add(const Duration(seconds: 1)),
        attachmentGeneration: 3,
      );

      expect(tracker.get(alice)!.state, RoomParticipantState.left);
    },
  );

  test(
    'transport replacement preserves roster and moves live members to reconnecting',
    () {
      final tracker = RoomPresenceTracker();
      for (final id in [alice, bob, carol]) {
        tracker.markJoining(id, attachmentGeneration: 1);
        tracker.observeInbound(id, at: t0, attachmentGeneration: 1);
        tracker.observeOutboundConfirmation(
          id,
          at: t0,
          attachmentGeneration: 1,
        );
      }

      tracker.replaceAttachment(2);

      expect(tracker.participants, hasLength(3));
      expect(tracker.participants.map((item) => item.state).toSet(), {
        RoomParticipantState.reconnecting,
      });
      expect(
        tracker.participants.map((item) => item.attachmentGeneration).toSet(),
        {2},
      );
    },
  );

  test('stale old-attachment evidence cannot overwrite a newer generation', () {
    final tracker = RoomPresenceTracker();
    tracker.markJoining(alice, attachmentGeneration: 1);
    tracker.replaceAttachment(2);

    tracker.observeInbound(alice, at: t0, attachmentGeneration: 1);
    tracker.observeOutboundConfirmation(alice, at: t0, attachmentGeneration: 1);

    expect(tracker.get(alice)!.attachmentGeneration, 2);
    expect(tracker.get(alice)!.state, RoomParticipantState.reconnecting);
  });

  test('one weak peer does not downgrade two healthy peers', () {
    final tracker = RoomPresenceTracker(
      evidenceFreshFor: const Duration(seconds: 5),
      reconnectGrace: const Duration(seconds: 10),
    );
    for (final id in [alice, bob, carol]) {
      tracker.markJoining(id, attachmentGeneration: 1);
      tracker.observeInbound(id, at: t0, attachmentGeneration: 1);
      tracker.observeOutboundConfirmation(id, at: t0, attachmentGeneration: 1);
    }

    final refreshed = t0.add(const Duration(seconds: 4));
    for (final id in [bob, carol]) {
      tracker.observeInbound(id, at: refreshed, attachmentGeneration: 1);
      tracker.observeOutboundConfirmation(
        id,
        at: refreshed,
        attachmentGeneration: 1,
      );
    }
    tracker.advance(t0.add(const Duration(seconds: 6)));

    expect(tracker.get(alice)!.state, RoomParticipantState.reconnecting);
    expect(tracker.get(bob)!.state, RoomParticipantState.connected);
    expect(tracker.get(carol)!.state, RoomParticipantState.connected);
  });

  test('dispose is deterministic and rejects later callbacks', () {
    final tracker = RoomPresenceTracker();
    tracker.addInvited(alice, attachmentGeneration: 1);
    tracker.dispose();
    tracker.dispose();

    expect(tracker.participants, isEmpty);
    expect(
      () => tracker.observeInbound(alice, at: t0, attachmentGeneration: 1),
      throwsStateError,
    );
  });
}
