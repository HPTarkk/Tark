import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_connection_coordinator.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  const owner = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa');
  const joiner = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');

  RoomTransportCandidate candidate(
    RoomMemberId id, {
    bool hotspot = true,
    bool preferred = false,
  }) => RoomTransportCandidate(
    memberId: id,
    canHostHotspot: hotspot,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: 80,
    prefersHotspotHost: preferred,
  );

  test(
    'simultaneous Start taps converge on one epoch and one hotspot host',
    () {
      final coordinator = RoomConnectionCoordinator();
      final first = coordinator.requestStart(
        requester: owner,
        sharedLanUsable: false,
        candidates: [candidate(owner, preferred: true), candidate(joiner)],
      );
      final second = coordinator.requestStart(
        requester: joiner,
        sharedLanUsable: false,
        candidates: [candidate(owner, preferred: true), candidate(joiner)],
      );

      expect(first.epoch, 1);
      expect(second.epoch, 1);
      expect(second.plan?.kind, RoomTransportKind.hotspot);
      expect(second.plan?.hotspotHost, owner);
      expect(second.startRequestedBy, {owner, joiner});
    },
  );

  test('shared LAN becomes connected only after transport and peer proof', () {
    final coordinator = RoomConnectionCoordinator();
    final requested = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: true,
      candidates: [candidate(owner), candidate(joiner)],
    );

    expect(requested.phase, RoomConnectionPhase.preparing);
    expect(requested.plan?.kind, RoomTransportKind.sharedLan);
    expect(
      coordinator.reportPeerProof(epoch: requested.epoch).phase,
      RoomConnectionPhase.preparing,
    );
    expect(
      coordinator.reportTransportReady(epoch: requested.epoch).phase,
      RoomConnectionPhase.waitingForPeerProof,
    );
    expect(
      coordinator.reportPeerProof(epoch: requested.epoch).phase,
      RoomConnectionPhase.connected,
    );
  });

  test('stale callback cannot revive a cancelled attempt', () {
    final coordinator = RoomConnectionCoordinator();
    final requested = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: [candidate(owner)],
    );
    coordinator.cancel(epoch: requested.epoch);

    expect(
      coordinator.reportTransportReady(epoch: requested.epoch).phase,
      RoomConnectionPhase.cancelled,
    );
    expect(
      coordinator.reportPeerProof(epoch: requested.epoch).phase,
      RoomConnectionPhase.cancelled,
    );
  });

  test('a new attempt advances epoch after cancellation', () {
    final coordinator = RoomConnectionCoordinator();
    final first = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: [candidate(owner)],
    );
    coordinator.cancel(epoch: first.epoch);
    final next = coordinator.requestStart(
      requester: joiner,
      sharedLanUsable: false,
      candidates: [candidate(joiner)],
    );

    expect(next.epoch, 2);
    expect(next.plan?.hotspotHost, joiner);
  });

  test('a connected Start can be ended so the next one plans afresh', () {
    final coordinator = RoomConnectionCoordinator();
    final first = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: true,
      candidates: const [],
    );
    coordinator.reportTransportReady(epoch: first.epoch);
    coordinator.reportPeerProof(epoch: first.epoch);
    expect(coordinator.state.phase, RoomConnectionPhase.connected);

    // Cancel leaves a live call alone, and a Start while connected is the
    // same attempt: that is what kept every later Start refused.
    coordinator.cancel(epoch: first.epoch);
    expect(
      coordinator
          .requestStart(
            requester: owner,
            sharedLanUsable: true,
            candidates: const [],
          )
          .isActive,
      isFalse,
    );

    coordinator.end(epoch: first.epoch);
    final next = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: true,
      candidates: const [],
    );
    expect(next.isActive, isTrue);
    expect(next.epoch, first.epoch + 1);
  });

  test('ending an old epoch leaves the current attempt alone', () {
    final coordinator = RoomConnectionCoordinator();
    final first = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: true,
      candidates: const [],
    );
    coordinator.end(epoch: first.epoch - 1);
    expect(coordinator.state.isActive, isTrue);
  });
}
