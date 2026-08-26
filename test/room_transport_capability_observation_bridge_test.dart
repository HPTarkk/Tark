import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/service/room_capability_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_transport_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';
import 'package:tark/feature/room/domain/service/room_transport_capability_observation_bridge.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_observation.dart';
import 'package:tark/feature/transfer/domain/repository/transport_capability_observation_source.dart';

void main() {
  RoomCapabilityFailoverRuntime runtime() {
    final session = RoomSessionRuntime(
      initialState: RoomSession.open(
        roomId: 'room-a',
        sessionId: 'session-a',
        localMemberId: 'me',
        memberIds: const ['peer-a'],
      ),
    );
    final failover = RoomFailoverRuntime(session: session);
    return RoomCapabilityFailoverRuntime(
      orchestrator: RoomFailoverTransportOrchestrator(
        runtime: failover,
        startTransport: (_) async => RoomFailoverTransportHandle(() async {}),
      ),
    );
  }

  TransportCapabilityObservation observation(String peerKey, DateTime at) =>
      TransportCapabilityObservation(
        peerKey: peerKey,
        observedAt: at,
        capability: const TransportCapabilityAdvertisement(
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 91,
          prefersHotspotHost: true,
        ),
      );

  test('bound admitted peer observation becomes planner evidence', () async {
    final subject = runtime();
    final source = _Source();
    final bridge = RoomTransportCapabilityObservationBridge(
      runtime: subject,
      source: source,
    );
    addTearDown(() async {
      await bridge.dispose();
      await source.dispose();
      subject.dispose();
    });
    expect(
      subject.bindPeer(
        peerKey: 'route-a',
        memberId: const RoomMemberId('peer-a'),
      ),
      isTrue,
    );
    final now = DateTime.utc(2026, 8, 27, 1);

    source.add(observation('route-a', now));

    final candidates = subject.candidates.snapshot(
      now: now,
      attachmentGeneration: subject.attachmentGeneration,
    );
    expect(candidates, hasLength(1));
    expect(candidates.single.memberId, const RoomMemberId('peer-a'));
    expect(candidates.single.batteryPercent, 91);
    expect(candidates.single.prefersHotspotHost, isTrue);
  });

  test('unbound transport peer fails closed', () async {
    final subject = runtime();
    final source = _Source();
    final bridge = RoomTransportCapabilityObservationBridge(
      runtime: subject,
      source: source,
    );
    addTearDown(() async {
      await bridge.dispose();
      await source.dispose();
      subject.dispose();
    });
    final now = DateTime.utc(2026, 8, 27, 1);

    source.add(observation('unbound-route', now));

    expect(
      subject.candidates.snapshot(
        now: now,
        attachmentGeneration: subject.attachmentGeneration,
      ),
      isEmpty,
    );
  });

  test('optional capability stream failure is non-terminal', () async {
    final subject = runtime();
    final source = _Source();
    final bridge = RoomTransportCapabilityObservationBridge(
      runtime: subject,
      source: source,
    );
    addTearDown(() async {
      await bridge.dispose();
      await source.dispose();
      subject.dispose();
    });
    expect(
      subject.bindPeer(
        peerKey: 'route-a',
        memberId: const RoomMemberId('peer-a'),
      ),
      isTrue,
    );
    final now = DateTime.utc(2026, 8, 27, 1);

    source.addError(StateError('capability unavailable'));
    source.add(observation('route-a', now));

    final candidates = subject.candidates.snapshot(
      now: now,
      attachmentGeneration: subject.attachmentGeneration,
    );
    expect(candidates, hasLength(1));
    expect(candidates.single.memberId, const RoomMemberId('peer-a'));
  });

  test(
    'replacement attachment rejects delayed old-route observation',
    () async {
      final subject = runtime();
      final source = _Source();
      final bridge = RoomTransportCapabilityObservationBridge(
        runtime: subject,
        source: source,
      );
      addTearDown(() async {
        await bridge.dispose();
        await source.dispose();
        subject.dispose();
      });
      expect(
        subject.bindPeer(
          peerKey: 'route-a',
          memberId: const RoomMemberId('peer-a'),
        ),
        isTrue,
      );
      final now = DateTime.utc(2026, 8, 27, 1);
      final attempt = await subject.beginFailover(
        sharedLanUsable: false,
        reason: RoomFailoverReason.hostLost,
        now: now,
      );
      expect(attempt, isNotNull);
      expect(subject.attachmentGeneration, 1);

      source.add(observation('route-a', now.add(const Duration(seconds: 1))));

      expect(
        subject.candidates.snapshot(
          now: now.add(const Duration(seconds: 1)),
          attachmentGeneration: subject.attachmentGeneration,
        ),
        isEmpty,
      );
    },
  );

  test('disposed bridge ignores later observations', () async {
    final subject = runtime();
    final source = _Source();
    final bridge = RoomTransportCapabilityObservationBridge(
      runtime: subject,
      source: source,
    );
    expect(
      subject.bindPeer(
        peerKey: 'route-a',
        memberId: const RoomMemberId('peer-a'),
      ),
      isTrue,
    );
    await bridge.dispose();
    final now = DateTime.utc(2026, 8, 27, 1);

    source.add(observation('route-a', now));

    expect(
      subject.candidates.snapshot(
        now: now,
        attachmentGeneration: subject.attachmentGeneration,
      ),
      isEmpty,
    );
    await source.dispose();
    subject.dispose();
  });
}

final class _Source implements TransportCapabilityObservationSource {
  final _controller =
      StreamController<TransportCapabilityObservation>.broadcast(sync: true);

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      _controller.stream;

  void add(TransportCapabilityObservation observation) {
    _controller.add(observation);
  }

  void addError(Object error) {
    _controller.addError(error);
  }

  Future<void> dispose() => _controller.close();
}
