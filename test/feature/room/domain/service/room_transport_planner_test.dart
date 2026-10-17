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

  test('the member who joined the room first wins a battery tie', () {
    final older = candidate(
      'member-z',
      battery: 81,
    ).withMemberSince(DateTime.utc(2026, 1, 1));
    final newer = candidate(
      'member-a',
      battery: 85,
    ).withMemberSince(DateTime.utc(2026, 3, 1));
    for (final inputs in [
      [older, newer],
      [newer, older],
    ]) {
      final plan = RoomTransportPlanner.plan(
        RoomTransportEnvironment(
          sharedLanUsable: false,
          epoch: 1,
          candidates: inputs,
        ),
      );
      expect(plan.hotspotHost, const RoomMemberId('member-z'));
    }
  });

  test('an unknown join time falls back to member identity', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: [
          candidate('member-z').withMemberSince(DateTime.utc(2026, 1, 1)),
          candidate('member-a'),
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

  test('no hotspot falls through instead of using Bluetooth', () {
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

    expect(plan.isUsable, isFalse);
    expect(plan.reason, RoomTransportPlanReason.noEligibleTransport);
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

  test(
    'cold bootstrap adopts one known side without fabricating capability',
    () {
      const bootstrap = RoomMemberId('creator');
      final plan = RoomTransportPlanner.plan(
        const RoomTransportEnvironment(
          sharedLanUsable: false,
          epoch: 6,
          candidates: [],
          bootstrapHotspotHost: bootstrap,
        ),
      );

      expect(plan.kind, RoomTransportKind.hotspot);
      expect(plan.hotspotHost, bootstrap);
      expect(plan.reason, RoomTransportPlanReason.deterministicHotspotHost);
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

  test('a live Room still needs a host whose keep-alive is up', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 2,
        candidates: [candidate('a', background: false)],
      ),
    );
    expect(plan.kind, isNot(RoomTransportKind.hotspot));
  });

  test('before the channel a host need not have its keep-alive up yet', () {
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 2,
        requireBackgroundReady: false,
        candidates: [
          candidate('a', background: false, battery: 40),
          candidate('b', background: false, battery: 90),
        ],
      ),
    );
    expect(plan.kind, RoomTransportKind.hotspot);
    expect(plan.hotspotHost, const RoomMemberId('b'));
  });

  test('a battery tick does not split the vote between two phones', () {
    // Each phone sees its own fresh reading and the other's last advertised
    // one. Within a band the order falls to the member id, the same on both.
    final onA = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: [candidate('a', battery: 71), candidate('b', battery: 72)],
      ),
    );
    final onB = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        epoch: 1,
        candidates: [candidate('a', battery: 72), candidate('b', battery: 71)],
      ),
    );
    expect(onA.hotspotHost, onB.hotspotHost);
  });
}
