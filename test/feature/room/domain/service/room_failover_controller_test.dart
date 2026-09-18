import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  RoomTransportCandidate candidate(
    String id, {
    bool hotspot = true,
    bool bluetooth = true,
    bool background = true,
    int battery = 80,
    bool preferred = false,
  }) => RoomTransportCandidate(
    memberId: RoomMemberId(id),
    canHostHotspot: hotspot,
    bluetoothSupported: bluetooth,
    backgroundReady: background,
    batteryPercent: battery,
    prefersHotspotHost: preferred,
  );

  test('host loss elects exactly one deterministic eligible replacement', () {
    final controller = RoomFailoverController(initialEpoch: 4);

    final decision = controller.failover(
      sharedLanUsable: false,
      candidates: [
        candidate('member-b', battery: 70),
        candidate('member-a', battery: 90),
      ],
      reason: RoomFailoverReason.hostLost,
    );

    expect(decision, isNotNull);
    expect(decision!.epoch, 5);
    expect(decision.plan.kind, RoomTransportKind.hotspot);
    expect(decision.plan.hotspotHost, const RoomMemberId('member-a'));
    expect(decision.requiresUserRescan, isTrue);
  });

  test('same candidate snapshot converges during simultaneous election', () {
    final candidates = [
      candidate('member-c', battery: 80),
      candidate('member-a', battery: 80),
      candidate('member-b', battery: 80),
    ];
    final first = RoomFailoverController(initialEpoch: 10).failover(
      sharedLanUsable: false,
      candidates: candidates,
      reason: RoomFailoverReason.hostLost,
    );
    final second = RoomFailoverController(initialEpoch: 10).failover(
      sharedLanUsable: false,
      candidates: candidates.reversed.toList(),
      reason: RoomFailoverReason.hostLost,
    );

    expect(first!.epoch, second!.epoch);
    expect(first.plan.hotspotHost, second.plan.hotspotHost);
    expect(first.plan.hotspotHost, const RoomMemberId('member-a'));
  });

  test('no hotspot candidate falls back without inventing a host', () {
    final controller = RoomFailoverController();

    final decision = controller.failover(
      sharedLanUsable: false,
      candidates: [candidate('member-a', hotspot: false, bluetooth: true)],
      reason: RoomFailoverReason.transportFailed,
    );

    expect(decision!.plan.kind, RoomTransportKind.bluetooth);
    expect(decision.plan.hotspotHost, isNull);
    expect(decision.requiresUserRescan, isFalse);
  });

  test('no eligible transport is represented honestly', () {
    final controller = RoomFailoverController();

    final decision = controller.failover(
      sharedLanUsable: false,
      candidates: [candidate('member-a', hotspot: false, bluetooth: false)],
      reason: RoomFailoverReason.hostLost,
    );

    expect(decision!.plan.isUsable, isFalse);
    expect(decision.plan.hotspotHost, isNull);
  });

  test('old host callback cannot revert a newer failover epoch', () {
    final controller = RoomFailoverController(initialEpoch: 2);
    final decision = controller.failover(
      sharedLanUsable: false,
      candidates: [candidate('replacement')],
      reason: RoomFailoverReason.hostLost,
    );

    expect(decision!.epoch, 3);
    expect(controller.acceptsEpoch(2), isFalse);
    expect(controller.acceptsEpoch(3), isTrue);
  });

  test('old host returning may participate only in a newer election', () {
    final controller = RoomFailoverController(initialEpoch: 6);
    controller.failover(
      sharedLanUsable: false,
      candidates: [candidate('new-host', battery: 80)],
      reason: RoomFailoverReason.hostLost,
    );

    final returned = controller.failover(
      sharedLanUsable: false,
      candidates: [
        candidate('old-host', battery: 90),
        candidate('new-host', battery: 80),
      ],
      reason: RoomFailoverReason.manualRetry,
    );

    expect(returned!.epoch, 8);
    expect(returned.plan.hotspotHost, const RoomMemberId('old-host'));
    expect(controller.acceptsEpoch(7), isFalse);
    expect(controller.acceptsEpoch(8), isTrue);
  });

  test('adoption rejects same or stale epoch to prevent split brain', () {
    final controller = RoomFailoverController(initialEpoch: 5);
    final stalePlan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        candidates: [candidate('member-a')],
        epoch: 5,
      ),
    );
    final stale = RoomFailoverDecision(
      epoch: 5,
      plan: stalePlan,
      reason: RoomFailoverReason.hostLost,
      requiresUserRescan: true,
    );

    expect(controller.adopt(stale), isFalse);
    expect(controller.epoch, 5);
  });

  test('explicit cancellation ignores later failover and callbacks', () {
    final controller = RoomFailoverController(initialEpoch: 3);
    controller.cancel();

    final decision = controller.failover(
      sharedLanUsable: false,
      candidates: [candidate('member-a')],
      reason: RoomFailoverReason.manualRetry,
    );

    expect(decision, isNull);
    expect(controller.acceptsEpoch(3), isFalse);
    expect(controller.epoch, 3);
  });

  test('usable shared LAN recovery needs no hotspot rescan', () {
    final controller = RoomFailoverController(initialEpoch: 1);

    final decision = controller.failover(
      sharedLanUsable: true,
      candidates: [candidate('member-a')],
      reason: RoomFailoverReason.hostLost,
    );

    expect(decision!.plan.kind, RoomTransportKind.sharedLan);
    expect(decision.requiresUserRescan, isFalse);
  });
}
