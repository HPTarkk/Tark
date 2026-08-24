import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_session_controller.dart';

void main() {
  RoomSessionController controller() => RoomSessionController(
    RoomSession.open(
      roomId: 'room-1',
      sessionId: 'session-1',
      localMemberId: 'me',
    ),
  );

  test('publishes typed transport lifecycle without changing room identity', () {
    final subject = controller();
    final seen = <RoomSession>[];
    final subscription = subject.changes.listen(seen.add);

    subject.attach(kind: TransportKind.hotspot, role: 'host');
    final generation = subject.state.attachment.generation;
    subject.attachmentReady(generation: generation);
    subject.attachmentDegraded(
      generation: generation,
      reason: 'peer_unconfirmed',
    );
    subject.recover(generation: generation, reason: 'network_lost');
    subject.replaceTransport(kind: TransportKind.wifi, role: 'peer');

    expect(seen.map((state) => state.phase), [
      RoomSessionPhase.recoveringTransport,
      RoomSessionPhase.live,
      RoomSessionPhase.degraded,
      RoomSessionPhase.recoveringTransport,
      RoomSessionPhase.recoveringTransport,
    ]);
    expect(seen.every((state) => state.roomId == 'room-1'), isTrue);

    subscription.cancel();
    subject.close();
  });

  test('stale callbacks produce no duplicate presentation state', () async {
    final subject = controller();
    final seen = <RoomSession>[];
    final subscription = subject.changes.listen(seen.add);

    subject.attach(kind: TransportKind.hotspot);
    final staleGeneration = subject.state.attachment.generation;
    subject.replaceTransport(kind: TransportKind.bluetooth);
    final before = seen.length;

    subject.attachmentReady(generation: staleGeneration);

    expect(seen.length, before);
    expect(subject.state.attachment.kind, TransportKind.bluetooth);

    await subscription.cancel();
    await subject.close();
  });
}
