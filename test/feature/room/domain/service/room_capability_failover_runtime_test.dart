import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/service/room_capability_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_transport_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';

void main() {
  RoomCapabilityFailoverRuntime subject() {
    final session = RoomSessionRuntime(
      initialState: RoomSession.open(
        roomId: 'room-a',
        sessionId: 'session-a',
        localMemberId: 'me',
        memberIds: const ['peer-a'],
      ),
    );
    final failover = RoomFailoverRuntime(session: session);
    final orchestrator = RoomFailoverTransportOrchestrator(
      runtime: failover,
      startTransport: (_) async => RoomFailoverTransportHandle(() async {}),
    );
    return RoomCapabilityFailoverRuntime(orchestrator: orchestrator);
  }

  void local(
    RoomCapabilityFailoverRuntime runtime,
    DateTime now, {
    int battery = 50,
  }) => runtime.observeLocal(
    canHostHotspot: true,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: battery,
    at: now,
  );

  test('unknown peer capability cannot influence host election', () async {
    final runtime = subject();
    final now = DateTime.utc(2026, 8, 26, 15);
    local(runtime, now, battery: 40);

    expect(
      runtime.observePeer(
        peerKey: 'attacker-route',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 100,
        at: now,
        prefersHotspotHost: true,
      ),
      isFalse,
    );

    final attempt = await runtime.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.hostLost,
      now: now,
    );

    expect(attempt, isNotNull);
    expect(attempt!.decision.plan.hotspotHost, const RoomMemberId('me'));
    runtime.dispose();
  });

  test(
    'bound admitted peer can participate in deterministic election',
    () async {
      final runtime = subject();
      final now = DateTime.utc(2026, 8, 26, 15);
      local(runtime, now, battery: 40);
      expect(
        runtime.bindPeer(
          peerKey: 'route-a',
          memberId: const RoomMemberId('peer-a'),
        ),
        isTrue,
      );
      expect(
        runtime.observePeer(
          peerKey: 'route-a',
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 90,
          at: now,
        ),
        isTrue,
      );

      final attempt = await runtime.beginFailover(
        sharedLanUsable: false,
        reason: RoomFailoverReason.hostLost,
        now: now,
      );

      expect(attempt, isNotNull);
      expect(attempt!.decision.plan.hotspotHost, const RoomMemberId('peer-a'));
      runtime.dispose();
    },
  );

  test(
    'replacement attachment invalidates old binding and capability',
    () async {
      final runtime = subject();
      final now = DateTime.utc(2026, 8, 26, 15);
      expect(
        runtime.bindPeer(
          peerKey: 'route-a',
          memberId: const RoomMemberId('peer-a'),
        ),
        isTrue,
      );
      expect(
        runtime.observePeer(
          peerKey: 'route-a',
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 80,
          at: now,
        ),
        isTrue,
      );

      final attempt = await runtime.beginFailover(
        sharedLanUsable: false,
        reason: RoomFailoverReason.hostLost,
        now: now,
      );
      expect(attempt!.attachmentGeneration, 1);
      expect(runtime.attachmentGeneration, 1);

      expect(
        runtime.observePeer(
          peerKey: 'route-a',
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 80,
          at: now.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        runtime.candidates.snapshot(
          now: now.add(const Duration(seconds: 1)),
          attachmentGeneration: 1,
        ),
        isEmpty,
      );
      runtime.dispose();
    },
  );

  test('membership removal invalidates binding and candidate immediately', () {
    final runtime = subject();
    final now = DateTime.utc(2026, 8, 26, 15);
    expect(
      runtime.bindPeer(
        peerKey: 'route-a',
        memberId: const RoomMemberId('peer-a'),
      ),
      isTrue,
    );
    expect(
      runtime.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 90,
        at: now,
      ),
      isTrue,
    );

    runtime.replaceMembers(const [RoomMemberId('me')]);

    expect(
      runtime.bindPeer(
        peerKey: 'route-a',
        memberId: const RoomMemberId('peer-a'),
      ),
      isFalse,
    );
    expect(
      runtime.candidates.snapshot(
        now: now,
        attachmentGeneration: runtime.attachmentGeneration,
      ),
      isEmpty,
    );
    runtime.dispose();
  });
}
