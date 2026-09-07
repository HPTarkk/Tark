import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_connection_coordinator.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  const owner = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa');
  const joiner = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');
  const third = RoomMemberId('cccccccccccccccccccccccc');

  RoomTransportCandidate candidate(
    RoomMemberId id, {
    bool preferred = false,
  }) => RoomTransportCandidate(
    memberId: id,
    canHostHotspot: true,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: id == owner ? 70 : 80,
    prefersHotspotHost: preferred,
  );

  List<RoomTransportCandidate> twoMemberCandidates({bool reversed = false}) {
    final values = [
      candidate(owner, preferred: true),
      candidate(joiner),
    ];
    return reversed ? values.reversed.toList() : values;
  }

  test('simultaneous Start on two phones elects exactly one hotspot host', () {
    final ownerPhone = RoomConnectionCoordinator();
    final joinerPhone = RoomConnectionCoordinator();

    final fromOwner = ownerPhone.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(),
    );
    final fromJoiner = joinerPhone.requestStart(
      requester: joiner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(reversed: true),
    );

    expect(fromOwner.epoch, 1);
    expect(fromJoiner.epoch, 1);
    expect(fromOwner.plan?.kind, RoomTransportKind.hotspot);
    expect(fromJoiner.plan?.kind, RoomTransportKind.hotspot);
    expect(fromOwner.plan?.hotspotHost, owner);
    expect(fromJoiner.plan?.hotspotHost, owner);
  });

  test('double tap stays on one epoch and never creates a second plan', () {
    final coordinator = RoomConnectionCoordinator();

    final first = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(),
    );
    final second = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(reversed: true),
    );

    expect(second.epoch, first.epoch);
    expect(second.plan, first.plan);
    expect(second.startRequestedBy, {owner});
  });

  test('resume rehydrates the active epoch instead of electing again', () {
    final beforePause = RoomConnectionCoordinator();
    final active = beforePause.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(),
    );

    final resumed = RoomConnectionCoordinator(initialState: active);
    final afterResume = resumed.requestStart(
      requester: joiner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(reversed: true),
    );

    expect(afterResume.epoch, active.epoch);
    expect(afterResume.plan, active.plan);
    expect(afterResume.startRequestedBy, {owner, joiner});
    expect(
      resumed.reportTransportReady(epoch: afterResume.epoch).phase,
      RoomConnectionPhase.waitingForPeerProof,
    );
    expect(
      resumed.reportPeerProof(epoch: afterResume.epoch).phase,
      RoomConnectionPhase.connected,
    );
  });

  test('cancel fences delayed native callbacks after a new attempt starts', () {
    final coordinator = RoomConnectionCoordinator();
    final cancelled = coordinator.requestStart(
      requester: owner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(),
    );
    coordinator.cancel(epoch: cancelled.epoch);

    final restarted = coordinator.requestStart(
      requester: joiner,
      sharedLanUsable: false,
      candidates: twoMemberCandidates(reversed: true),
    );
    expect(restarted.epoch, cancelled.epoch + 1);

    expect(
      coordinator.reportTransportReady(epoch: cancelled.epoch).epoch,
      restarted.epoch,
    );
    expect(
      coordinator.reportPeerProof(epoch: cancelled.epoch).phase,
      RoomConnectionPhase.preparing,
    );
    expect(coordinator.state.plan?.hotspotHost, owner);
  });

  test('three phones independently converge on the same hotspot host', () {
    final candidateSets = <RoomMemberId, List<RoomTransportCandidate>>{
      owner: [
        candidate(third),
        candidate(joiner),
        candidate(owner, preferred: true),
      ],
      joiner: [
        candidate(owner, preferred: true),
        candidate(third),
        candidate(joiner),
      ],
      third: [
        candidate(joiner),
        candidate(owner, preferred: true),
        candidate(third),
      ],
    };
    final devices = <RoomMemberId, RoomConnectionState>{
      for (final entry in candidateSets.entries)
        entry.key: RoomConnectionCoordinator().requestStart(
          requester: entry.key,
          sharedLanUsable: false,
          candidates: entry.value,
        ),
    };

    expect(devices.values.map((state) => state.epoch).toSet(), {1});
    expect(
      devices.values.map((state) => state.plan?.kind).toSet(),
      {RoomTransportKind.hotspot},
    );
    expect(
      devices.values.map((state) => state.plan?.hotspotHost).toSet(),
      {owner},
    );
  });
}
