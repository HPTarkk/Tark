import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';
import 'package:tark/feature/room/domain/service/room_transport_health_runtime_adapter.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  RoomSessionRuntime room() => RoomSessionRuntime(
    initialState: RoomSession.open(
      roomId: 'room-a',
      sessionId: 'session-a',
      localMemberId: 'me',
      memberIds: const ['peer-a'],
      isMuted: true,
    ),
  );

  test('maps live health without changing durable room identity', () async {
    final runtime = room();
    final health = StreamController<ConnectionHealth>.broadcast(sync: true);
    final adapter = RoomTransportHealthRuntimeAdapter(runtime);

    final generation = await adapter.attach(
      kind: TransportKind.wifi,
      role: 'peer',
      health: health.stream,
    );
    health.add(const ConnectionHealth.healthy());
    expect(runtime.state.phase, RoomSessionPhase.live);
    expect(runtime.state.roomId, 'room-a');
    expect(runtime.state.memberIds, containsAll(['me', 'peer-a']));
    expect(runtime.state.isMuted, isTrue);

    health.add(const ConnectionHealth.degraded());
    expect(runtime.state.attachment.phase, TransportAttachmentPhase.degraded);
    expect(runtime.state.roomId, 'room-a');

    health.add(const ConnectionHealth.reconnecting());
    expect(runtime.state.phase, RoomSessionPhase.recoveringTransport);
    expect(runtime.state.attachment.generation, generation);
    expect(runtime.state.roomId, 'room-a');

    health.add(const ConnectionHealth.healthy());
    expect(runtime.state.phase, RoomSessionPhase.live);
    expect(runtime.hasLeft, isFalse);

    await runtime.leave();
    await health.close();
  });

  test(
    'replacement disposes old health subscription and ignores stale events',
    () async {
      final runtime = room();
      final first = StreamController<ConnectionHealth>.broadcast(sync: true);
      final second = StreamController<ConnectionHealth>.broadcast(sync: true);
      final adapter = RoomTransportHealthRuntimeAdapter(runtime);

      final firstGeneration = await adapter.attach(
        kind: TransportKind.wifi,
        health: first.stream,
      );
      first.add(const ConnectionHealth.healthy());

      final secondGeneration = await adapter.replace(
        kind: TransportKind.bluetooth,
        role: 'client',
        health: second.stream,
        reason: 'wifi_replacement',
      );
      expect(secondGeneration, firstGeneration + 1);
      expect(runtime.state.attachment.kind, TransportKind.bluetooth);

      first.add(const ConnectionHealth.down());
      expect(runtime.state.attachment.generation, secondGeneration);
      expect(
        runtime.state.attachment.phase,
        TransportAttachmentPhase.connecting,
      );

      second.add(const ConnectionHealth.healthy());
      expect(runtime.state.phase, RoomSessionPhase.live);
      expect(runtime.state.attachment.kind, TransportKind.bluetooth);

      await runtime.leave();
      await first.close();
      await second.close();
    },
  );

  test(
    'down and stream failure remain transport failures, not room leave',
    () async {
      final runtime = room();
      final health = StreamController<ConnectionHealth>.broadcast(sync: true);
      final adapter = RoomTransportHealthRuntimeAdapter(runtime);

      await adapter.attach(kind: TransportKind.wifi, health: health.stream);
      health.add(const ConnectionHealth.down());
      expect(runtime.state.attachment.phase, TransportAttachmentPhase.failed);
      expect(runtime.state.isLogicallyPresent, isTrue);
      expect(runtime.hasLeft, isFalse);

      final replacement = StreamController<ConnectionHealth>.broadcast(
        sync: true,
      );
      await adapter.replace(
        kind: TransportKind.wifi,
        health: replacement.stream,
        reason: 'manual_retry',
      );
      replacement.addError(StateError('native stream failed'));
      expect(runtime.state.attachment.phase, TransportAttachmentPhase.failed);
      expect(runtime.state.recoveryReason, 'transport_health_stream_error');
      expect(runtime.hasLeft, isFalse);

      await runtime.leave();
      await health.close();
      await replacement.close();
    },
  );

  test(
    'explicit leave disposes the current health subscription once',
    () async {
      final runtime = room();
      var listens = 0;
      var cancels = 0;
      late StreamController<ConnectionHealth> health;
      health = StreamController<ConnectionHealth>.broadcast(
        sync: true,
        onListen: () => listens++,
        onCancel: () => cancels++,
      );
      final adapter = RoomTransportHealthRuntimeAdapter(runtime);

      await adapter.attach(kind: TransportKind.wifi, health: health.stream);
      expect(listens, 1);
      await runtime.leave();
      await runtime.leave();
      expect(cancels, 1);

      await health.close();
    },
  );
}
