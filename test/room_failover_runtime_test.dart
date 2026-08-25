import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  RoomSessionRuntime session() => RoomSessionRuntime(
    initialState: RoomSession.open(
      roomId: 'room-stable',
      sessionId: 'session-a',
      localMemberId: 'me',
      memberIds: const ['peer-a', 'peer-b'],
      isMuted: true,
    ),
  );

  RoomTransportCandidate candidate(
    String id, {
    int battery = 50,
    bool canHost = true,
    bool backgroundReady = true,
  }) => RoomTransportCandidate(
    memberId: RoomMemberId(id),
    canHostHotspot: canHost,
    bluetoothSupported: true,
    backgroundReady: backgroundReady,
    batteryPercent: battery,
  );

  test(
    'host failover replaces only attachment and preserves logical room',
    () async {
      final room = session();
      final initial = await room.attach(
        kind: TransportKind.hotspot,
        role: 'joiner',
      );
      room.ready(generation: initial, role: 'joiner');
      final runtime = RoomFailoverRuntime(session: room);

      final attempt = await runtime.begin(
        sharedLanUsable: false,
        candidates: [
          candidate('peer-a', battery: 90),
          candidate('me', battery: 60),
        ],
        reason: RoomFailoverReason.hostLost,
      );

      expect(attempt, isNotNull);
      expect(attempt!.decision.epoch, 1);
      expect(attempt.decision.plan.kind, RoomTransportKind.hotspot);
      expect(attempt.decision.plan.hotspotHost, const RoomMemberId('peer-a'));
      expect(attempt.decision.requiresUserRescan, isTrue);
      expect(attempt.attachmentGeneration, initial + 1);
      expect(room.state.roomId, 'room-stable');
      expect(room.state.memberIds, containsAll(['me', 'peer-a', 'peer-b']));
      expect(room.state.isMuted, isTrue);
      expect(room.state.phase, RoomSessionPhase.recoveringTransport);
      expect(room.state.attachment.kind, TransportKind.hotspot);
      expect(room.state.attachment.role, 'joiner');
      expect(room.state.isLogicallyPresent, isTrue);
    },
  );

  test('local elected hotspot candidate becomes transport host only', () async {
    final room = session();
    final runtime = RoomFailoverRuntime(session: room);

    final attempt = await runtime.begin(
      sharedLanUsable: false,
      candidates: [
        candidate('me', battery: 95),
        candidate('peer-a', battery: 50),
      ],
      reason: RoomFailoverReason.transportFailed,
    );

    expect(attempt!.decision.plan.hotspotHost, const RoomMemberId('me'));
    expect(room.state.attachment.role, 'host');
    expect(room.state.localMemberId, 'me');
    expect(room.state.roomId, 'room-stable');
  });

  test('old host callbacks cannot overwrite a newer failover', () async {
    final room = session();
    final runtime = RoomFailoverRuntime(session: room);

    final first = (await runtime.begin(
      sharedLanUsable: false,
      candidates: [candidate('peer-a')],
      reason: RoomFailoverReason.hostLost,
    ))!;
    final second = (await runtime.begin(
      sharedLanUsable: true,
      candidates: [candidate('peer-a')],
      reason: RoomFailoverReason.manualRetry,
    ))!;

    expect(second.decision.epoch, first.decision.epoch + 1);
    expect(second.attachmentGeneration, first.attachmentGeneration! + 1);
    expect(
      runtime.ready(
        failoverEpoch: first.decision.epoch,
        attachmentGeneration: first.attachmentGeneration!,
        role: 'old-host',
      ),
      isFalse,
    );
    expect(room.state.phase, RoomSessionPhase.recoveringTransport);
    expect(room.state.attachment.kind, TransportKind.wifi);

    expect(
      runtime.ready(
        failoverEpoch: second.decision.epoch,
        attachmentGeneration: second.attachmentGeneration!,
        role: 'peer',
      ),
      isTrue,
    );
    expect(room.state.phase, RoomSessionPhase.live);
    expect(room.state.attachment.role, 'peer');
  });

  test('strictly newer simultaneous election can be adopted once', () async {
    final room = session();
    final runtime = RoomFailoverRuntime(session: room);
    final first = (await runtime.begin(
      sharedLanUsable: false,
      candidates: [candidate('peer-a')],
      reason: RoomFailoverReason.hostLost,
    ))!;

    const remote = RoomFailoverDecision(
      epoch: 2,
      plan: RoomTransportPlan(
        epoch: 2,
        kind: RoomTransportKind.bluetooth,
        reason: RoomTransportPlanReason.bluetoothFallback,
      ),
      reason: RoomFailoverReason.transportFailed,
      requiresUserRescan: false,
    );
    final adopted = await runtime.adopt(remote);

    expect(adopted, isNotNull);
    expect(adopted!.decision.epoch, 2);
    expect(room.state.attachment.kind, TransportKind.bluetooth);
    expect(await runtime.adopt(remote), isNull);
    expect(
      runtime.failed(
        failoverEpoch: first.decision.epoch,
        attachmentGeneration: first.attachmentGeneration!,
        reason: 'late_old_host',
      ),
      isFalse,
    );
  });

  test(
    'no eligible transport stays in the room with honest recovery state',
    () async {
      final room = session();
      final generation = await room.attach(
        kind: TransportKind.hotspot,
        role: 'host',
      );
      room.ready(generation: generation, role: 'host');
      final runtime = RoomFailoverRuntime(session: room);

      final attempt = await runtime.begin(
        sharedLanUsable: false,
        candidates: const [],
        reason: RoomFailoverReason.hostLost,
      );

      expect(attempt, isNotNull);
      expect(attempt!.decision.plan.kind, isNull);
      expect(attempt.attachmentGeneration, isNull);
      expect(room.state.phase, RoomSessionPhase.recoveringTransport);
      expect(room.state.attachment.phase, TransportAttachmentPhase.failed);
      expect(room.state.recoveryReason, 'failover_no_eligible_transport');
      expect(room.state.isLogicallyPresent, isTrue);
      expect(room.state.roomId, 'room-stable');
    },
  );

  test(
    'cancel rejects later callbacks without logically leaving room',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final attempt = (await runtime.begin(
        sharedLanUsable: false,
        candidates: [candidate('peer-a')],
        reason: RoomFailoverReason.hostLost,
      ))!;

      runtime.cancel();

      expect(runtime.controller.isCancelled, isTrue);
      expect(room.state.isLogicallyPresent, isTrue);
      expect(room.hasLeft, isFalse);
      expect(
        runtime.ready(
          failoverEpoch: attempt.decision.epoch,
          attachmentGeneration: attempt.attachmentGeneration!,
        ),
        isFalse,
      );
      expect(
        await runtime.begin(
          sharedLanUsable: true,
          candidates: [candidate('me')],
          reason: RoomFailoverReason.manualRetry,
        ),
        isNull,
      );
    },
  );
}
