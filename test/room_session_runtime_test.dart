import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';

void main() {
  RoomSessionRuntime runtime() => RoomSessionRuntime(
    initialState: RoomSession.open(
      roomId: 'room-a',
      sessionId: 'session-a',
      localMemberId: 'me',
      memberIds: const ['peer'],
      isMuted: true,
    ),
  );

  test('transport replacement preserves logical room, members and mute', () async {
    final value = runtime();
    final first = await value.attach(
      kind: TransportKind.hotspot,
      role: 'host',
    );
    value.ready(generation: first, role: 'host');

    final replacement = await value.replaceTransport(
      kind: TransportKind.wifi,
      role: 'peer',
      reason: 'network_changed',
    );

    expect(replacement, first + 1);
    expect(value.state.roomId, 'room-a');
    expect(value.state.sessionId, 'session-a');
    expect(value.state.memberIds, containsAll(['me', 'peer']));
    expect(value.state.isMuted, isTrue);
    expect(value.state.phase, RoomSessionPhase.recoveringTransport);
    expect(value.state.attachment.kind, TransportKind.wifi);
  });

  test('replacement disposes old attachment but keeps room resources', () async {
    final value = runtime();
    var roomDisposed = 0;
    var firstAttachmentDisposed = 0;
    var secondAttachmentDisposed = 0;
    value.ownRoomResource('audio', () => roomDisposed++);

    final first = await value.attach(kind: TransportKind.hotspot);
    expect(
      value.ownCurrentAttachmentResource(
        first,
        'socket',
        () => firstAttachmentDisposed++,
      ),
      isTrue,
    );

    final second = await value.replaceTransport(kind: TransportKind.wifi);
    expect(firstAttachmentDisposed, 1);
    expect(roomDisposed, 0);
    expect(
      value.ownCurrentAttachmentResource(
        second,
        'socket',
        () => secondAttachmentDisposed++,
      ),
      isTrue,
    );

    await value.leave();
    expect(firstAttachmentDisposed, 1);
    expect(secondAttachmentDisposed, 1);
    expect(roomDisposed, 1);
  });

  test('stale generation cannot register resources or change state', () async {
    final value = runtime();
    final first = await value.attach(kind: TransportKind.hotspot);
    final second = await value.replaceTransport(kind: TransportKind.wifi);

    expect(
      value.ownCurrentAttachmentResource(first, 'stale', () {}),
      isFalse,
    );
    value.ready(generation: first, role: 'old-host');
    expect(value.state.attachment.generation, second);
    expect(value.state.phase, RoomSessionPhase.recoveringTransport);

    value.ready(generation: second, role: 'peer');
    expect(value.state.phase, RoomSessionPhase.live);
    expect(value.state.attachment.role, 'peer');
  });

  test('degraded and recovery transitions do not logically leave room', () async {
    final value = runtime();
    final generation = await value.attach(kind: TransportKind.wifi);
    value.ready(generation: generation);
    value.degraded(generation: generation, reason: 'one_way');
    expect(value.state.phase, RoomSessionPhase.degraded);
    expect(value.state.isLogicallyPresent, isTrue);

    value.recover(generation: generation, reason: 'network_lost');
    expect(value.state.phase, RoomSessionPhase.recoveringTransport);
    expect(value.state.isLogicallyPresent, isTrue);
  });

  test('explicit leave is terminal and disposes resources exactly once', () async {
    final value = runtime();
    var roomDisposed = 0;
    var attachmentDisposed = 0;
    value.ownRoomResource('audio', () => roomDisposed++);
    final generation = await value.attach(kind: TransportKind.bluetooth);
    value.ownCurrentAttachmentResource(
      generation,
      'connection',
      () => attachmentDisposed++,
    );

    await value.leave();
    await value.leave();

    expect(value.state.phase, RoomSessionPhase.left);
    expect(value.hasLeft, isTrue);
    expect(roomDisposed, 1);
    expect(attachmentDisposed, 1);
    expect(
      () => value.setMuted(false),
      throwsA(isA<StateError>()),
    );
  });

  test('repeated replacements do not leak old attachment resources', () async {
    final value = runtime();
    var disposed = 0;

    for (var i = 0; i < 20; i++) {
      final generation = i == 0
          ? await value.attach(kind: TransportKind.wifi)
          : await value.replaceTransport(kind: TransportKind.wifi);
      value.ownCurrentAttachmentResource(
        generation,
        'socket',
        () => disposed++,
      );
    }

    expect(disposed, 19);
    await value.leave();
    expect(disposed, 20);
  });
}
