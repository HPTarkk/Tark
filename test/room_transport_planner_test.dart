import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
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

  test('usable shared LAN wins and does not elect a hotspot host', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: true,
        epoch: 4,
        candidates: [candidate('a'), candidate('b')],
      ),
    );

    expect(plan.kind, RoomTransportKind.sharedLan);
    expect(plan.reason, RoomTransportPlanReason.usableSharedLan);
    expect(plan.hotspotHost, isNull);
  });

  test('preferred eligible hotspot host is a policy hint, not room owner', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 9,
        candidates: [
          candidate('member-a', battery: 95),
          candidate('member-b', preferred: true, battery: 45),
          candidate('member-c', battery: 70),
        ],
      ),
    );

    expect(plan.kind, RoomTransportKind.hotspot);
    expect(plan.hotspotHost, const RoomMemberId('member-b'));
    expect(plan.reason, RoomTransportPlanReason.preferredHotspotHost);
  });

  test('unavailable preferred host falls through to eligible candidate', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 3,
        candidates: [
          candidate('preferred', preferred: true, background: false),
          candidate('eligible', battery: 50),
        ],
      ),
    );

    expect(plan.hotspotHost, const RoomMemberId('eligible'));
  });

  test('battery breaks ties before stable member identity', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: [
          candidate('member-z', battery: 70),
          candidate('member-a', battery: 90),
        ],
      ),
    );

    expect(plan.hotspotHost, const RoomMemberId('member-a'));
  });

  test('stable member identity deterministically breaks equal ties', () {
    final inputs = [
      candidate('member-c', battery: 80),
      candidate('member-a', battery: 80),
      candidate('member-b', battery: 80),
    ];
    final forward = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: inputs,
      ),
    );
    final reversed = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: inputs.reversed.toList(),
      ),
    );

    expect(forward.hotspotHost, const RoomMemberId('member-a'));
    expect(reversed.hotspotHost, forward.hotspotHost);
  });

  test('Bluetooth is fallback only when no eligible hotspot host exists', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 2,
        candidates: [
          candidate('a', hotspot: false),
          candidate('b', hotspot: true, background: false),
        ],
      ),
    );

    expect(plan.kind, RoomTransportKind.bluetooth);
    expect(plan.reason, RoomTransportPlanReason.bluetoothFallback);
  });

  test(
    'no eligible capability fails honestly instead of inventing transport',
    () {
      final plan = RoomTransportPlanner.plan(
        RoomTransportEnvironment(
          sharedLanUsable: false,
          epoch: 2,
          candidates: [candidate('a', hotspot: false, bluetooth: false)],
        ),
      );

      expect(plan.isUsable, isFalse);
      expect(plan.reason, RoomTransportPlanReason.noEligibleTransport);
    },
  );

  test('explicit guest selection does not participate in hotspot election', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        guestExplicitlySelected: true,
        epoch: 5,
        candidates: [candidate('a')],
      ),
    );

    expect(plan.kind, RoomTransportKind.guest);
    expect(plan.hotspotHost, isNull);
  });

  test('election epoch rejects stale decisions', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 12,
        candidates: [candidate('a')],
      ),
    );

    expect(plan.isNewerThan(11), isTrue);
    expect(plan.isNewerThan(12), isFalse);
    expect(plan.isNewerThan(13), isFalse);
  });

  test('same policy scales deterministically to five candidates', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 7,
        candidates: [
          candidate('e', battery: 20),
          candidate('d', battery: 40),
          candidate('c', battery: 60),
          candidate('b', battery: 80),
          candidate('a', battery: 100),
        ],
      ),
    );

    expect(plan.hotspotHost, const RoomMemberId('a'));
  });
}
