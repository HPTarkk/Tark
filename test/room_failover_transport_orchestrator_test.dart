import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_transport_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';
import 'package:tark/feature/room/domain/service/room_transport_candidate_registry.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  RoomSessionRuntime session() => RoomSessionRuntime(
    initialState: RoomSession.open(
      roomId: 'room-stable',
      sessionId: 'session-a',
      localMemberId: 'me',
      memberIds: const ['peer-a'],
      isMuted: true,
    ),
  );

  RoomTransportCandidate candidate(String id, {int battery = 50}) =>
      RoomTransportCandidate(
        memberId: RoomMemberId(id),
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: battery,
      );

  test(
    'starts replacement transport and gates callbacks to its epoch',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      late RoomFailoverTransportContext context;
      var disposed = 0;
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (value) async {
          context = value;
          return RoomFailoverTransportHandle(() async => disposed++);
        },
      );

      final attempt = await orchestrator.begin(
        sharedLanUsable: false,
        candidates: [candidate('me', battery: 90), candidate('peer-a')],
        reason: RoomFailoverReason.hostLost,
      );

      expect(attempt, isNotNull);
      expect(room.state.roomId, 'room-stable');
      expect(room.state.memberIds, containsAll(['me', 'peer-a']));
      expect(room.state.isMuted, isTrue);
      expect(room.state.attachment.role, 'host');
      expect(
        room.resources.attachmentResourceCount(attempt!.attachmentGeneration!),
        1,
      );

      expect(context.callbacks.ready(role: 'host'), isTrue);
      expect(room.state.phase, RoomSessionPhase.live);
      expect(disposed, 0);
    },
  );

  test(
    'registry-backed failover uses only current fresh verified candidates',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final registry = RoomTransportCandidateRegistry(
        freshFor: const Duration(seconds: 10),
      );
      final now = DateTime.utc(2026, 8, 26, 14);
      registry.observe(
        candidate('stale-high', battery: 100),
        at: now,
        attachmentGeneration: 1,
      );
      registry.observe(
        candidate('peer-a', battery: 60),
        at: now,
        attachmentGeneration: 2,
      );
      registry.observe(
        candidate('me', battery: 90),
        at: now,
        attachmentGeneration: 2,
      );
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (_) async => RoomFailoverTransportHandle(() async {}),
      );

      final attempt = await orchestrator.beginFromRegistry(
        sharedLanUsable: false,
        candidates: registry,
        attachmentGeneration: 2,
        now: now.add(const Duration(seconds: 1)),
        reason: RoomFailoverReason.hostLost,
      );

      expect(attempt, isNotNull);
      expect(attempt!.decision.plan.kind, RoomTransportKind.hotspot);
      expect(attempt.decision.plan.hotspotHost, const RoomMemberId('me'));
      expect(room.state.attachment.role, 'host');
      registry.dispose();
    },
  );

  test(
    'registry-backed failover fails closed when all capability evidence expired',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final registry = RoomTransportCandidateRegistry(
        freshFor: const Duration(seconds: 5),
      );
      final observedAt = DateTime.utc(2026, 8, 26, 14);
      registry.observe(
        candidate('me', battery: 100),
        at: observedAt,
        attachmentGeneration: 4,
      );
      var starts = 0;
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (_) async {
          starts++;
          return RoomFailoverTransportHandle(() async {});
        },
      );

      final attempt = await orchestrator.beginFromRegistry(
        sharedLanUsable: false,
        candidates: registry,
        attachmentGeneration: 4,
        now: observedAt.add(const Duration(seconds: 6)),
        reason: RoomFailoverReason.hostLost,
      );

      expect(attempt, isNotNull);
      expect(attempt!.attachmentGeneration, isNull);
      expect(starts, 0);
      expect(room.state.isLogicallyPresent, isTrue);
      registry.dispose();
    },
  );

  test(
    'new failover disposes the previous transport and rejects stale callbacks',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final contexts = <RoomFailoverTransportContext>[];
      final disposed = <int>[];
      var starts = 0;
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (context) async {
          contexts.add(context);
          final id = starts++;
          return RoomFailoverTransportHandle(() async => disposed.add(id));
        },
      );

      final first = (await orchestrator.begin(
        sharedLanUsable: false,
        candidates: [candidate('peer-a')],
        reason: RoomFailoverReason.hostLost,
      ))!;
      final second = (await orchestrator.begin(
        sharedLanUsable: true,
        candidates: [candidate('peer-a')],
        reason: RoomFailoverReason.manualRetry,
      ))!;

      expect(second.attachmentGeneration, first.attachmentGeneration! + 1);
      expect(disposed, [0]);
      expect(contexts.first.callbacks.ready(role: 'old-host'), isFalse);
      expect(contexts.last.callbacks.ready(role: 'peer'), isTrue);
      expect(room.state.attachment.kind, TransportKind.wifi);
      expect(room.state.attachment.role, 'peer');
    },
  );

  test(
    'stale transport completing after a newer election is disposed immediately',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      var starts = 0;
      var staleDisposed = 0;
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (context) async {
          final id = starts++;
          if (id == 0) {
            firstStarted.complete();
            await releaseFirst.future;
            return RoomFailoverTransportHandle(() async => staleDisposed++);
          }
          return RoomFailoverTransportHandle(() async {});
        },
      );

      final firstFuture = orchestrator.begin(
        sharedLanUsable: false,
        candidates: [candidate('peer-a')],
        reason: RoomFailoverReason.hostLost,
      );
      await firstStarted.future;
      final second = await orchestrator.begin(
        sharedLanUsable: true,
        candidates: [candidate('peer-a')],
        reason: RoomFailoverReason.manualRetry,
      );
      releaseFirst.complete();
      await firstFuture;

      expect(second, isNotNull);
      expect(staleDisposed, 1);
      expect(room.state.attachment.kind, TransportKind.wifi);
    },
  );

  test(
    'start failure is reported on the current attachment without leaving room',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (_) async => throw StateError('native start failed'),
      );

      final attempt = await orchestrator.begin(
        sharedLanUsable: false,
        candidates: [candidate('me')],
        reason: RoomFailoverReason.transportFailed,
      );

      expect(attempt, isNotNull);
      expect(room.state.attachment.phase, TransportAttachmentPhase.failed);
      expect(room.state.recoveryReason, 'failover_transport_start_failed');
      expect(room.state.isLogicallyPresent, isTrue);
    },
  );

  test('no candidate does not start a transport', () async {
    final room = session();
    final runtime = RoomFailoverRuntime(session: room);
    var starts = 0;
    final orchestrator = RoomFailoverTransportOrchestrator(
      runtime: runtime,
      startTransport: (_) async {
        starts++;
        return RoomFailoverTransportHandle(() async {});
      },
    );

    final attempt = await orchestrator.begin(
      sharedLanUsable: false,
      candidates: const [],
      reason: RoomFailoverReason.hostLost,
    );

    expect(attempt, isNotNull);
    expect(attempt!.attachmentGeneration, isNull);
    expect(starts, 0);
    expect(room.state.isLogicallyPresent, isTrue);
  });

  test(
    'cancel disposes active replacement without leaving durable room',
    () async {
      final room = session();
      final runtime = RoomFailoverRuntime(session: room);
      var disposed = 0;
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: runtime,
        startTransport: (_) async =>
            RoomFailoverTransportHandle(() async => disposed++),
      );

      await orchestrator.begin(
        sharedLanUsable: false,
        candidates: [candidate('me')],
        reason: RoomFailoverReason.hostLost,
      );
      await orchestrator.cancel();

      expect(disposed, 1);
      expect(runtime.controller.isCancelled, isTrue);
      expect(room.hasLeft, isFalse);
      expect(room.state.roomId, 'room-stable');
      expect(room.state.memberIds, containsAll(['me', 'peer-a']));
    },
  );
}
