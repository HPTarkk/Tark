import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';

void main() {
  RoomSession openSession() => RoomSession.open(
    roomId: 'room-stable',
    sessionId: 'session-1',
    localMemberId: 'me',
    memberIds: const {'rider-a', 'rider-b'},
    isMuted: true,
  );

  test('open -> live keeps logical identity and member state', () {
    final open = openSession();
    final attaching = open.startAttachment(
      kind: TransportKind.hotspot,
      role: 'host',
    );
    final live = attaching.attachmentReady(
      generation: attaching.attachment.generation,
    );

    expect(live.phase, RoomSessionPhase.live);
    expect(live.attachment.phase, TransportAttachmentPhase.attached);
    expect(live.roomId, open.roomId);
    expect(live.sessionId, open.sessionId);
    expect(live.memberIds, open.memberIds);
    expect(live.isMuted, isTrue);
  });

  test('degraded and recovering transport never logically leave the room', () {
    final attaching = openSession().startAttachment(kind: TransportKind.wifi);
    final live = attaching.attachmentReady(
      generation: attaching.attachment.generation,
    );
    final degraded = live.attachmentDegraded(
      generation: live.attachment.generation,
      reason: 'peer_unconfirmed',
    );
    final recovering = degraded.beginTransportRecovery(
      generation: degraded.attachment.generation,
      reason: 'network_lost',
    );

    expect(degraded.phase, RoomSessionPhase.degraded);
    expect(recovering.phase, RoomSessionPhase.recoveringTransport);
    expect(recovering.isLogicallyPresent, isTrue);
    expect(recovering.roomId, live.roomId);
    expect(recovering.memberIds, live.memberIds);
  });

  test('transport role and kind can change without changing room identity', () {
    final first = openSession().startAttachment(
      kind: TransportKind.hotspot,
      role: 'host',
    );
    final firstLive = first.attachmentReady(
      generation: first.attachment.generation,
    );
    final replacement = firstLive.replaceTransport(
      kind: TransportKind.wifi,
      role: 'peer',
      reason: 'shared_lan_available',
    );
    final restored = replacement.attachmentReady(
      generation: replacement.attachment.generation,
    );

    expect(restored.roomId, firstLive.roomId);
    expect(restored.sessionId, firstLive.sessionId);
    expect(restored.attachment.kind, TransportKind.wifi);
    expect(restored.attachment.role, 'peer');
    expect(
      restored.attachment.generation,
      greaterThan(firstLive.attachment.generation),
    );
  });

  test('stale callback from an older attachment generation is ignored', () {
    final first = openSession().startAttachment(kind: TransportKind.hotspot);
    final firstGeneration = first.attachment.generation;
    final replacement = first.replaceTransport(kind: TransportKind.bluetooth);

    final staleReady = replacement.attachmentReady(
      generation: firstGeneration,
    );

    expect(staleReady, replacement);
    expect(staleReady.attachment.kind, TransportKind.bluetooth);
    expect(staleReady.phase, RoomSessionPhase.recoveringTransport);
  });

  test('explicit leave is terminal and idempotent', () {
    final attaching = openSession().startAttachment(kind: TransportKind.hotspot);
    final live = attaching.attachmentReady(
      generation: attaching.attachment.generation,
    );
    final left = live.leave();

    expect(left.phase, RoomSessionPhase.left);
    expect(left.attachment.phase, TransportAttachmentPhase.disposed);
    expect(left.leave(), same(left));
    expect(
      () => left.startAttachment(kind: TransportKind.wifi),
      throwsStateError,
    );
  });

  test('roster and mute survive attachment replacement', () {
    final session = openSession().setMuted(false).updateMembers({
      'rider-a',
      'rider-b',
      'late-rider',
    });
    final first = session.startAttachment(kind: TransportKind.hotspot);
    final firstLive = first.attachmentReady(
      generation: first.attachment.generation,
    );
    final replacement = firstLive.replaceTransport(kind: TransportKind.wifi);

    expect(
      replacement.memberIds,
      containsAll(['me', 'rider-a', 'rider-b', 'late-rider']),
    );
    expect(replacement.isMuted, isFalse);
  });
}
