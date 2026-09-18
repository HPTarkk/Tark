import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_carrier.dart';
import 'package:tark/feature/room/domain/service/room_carrier_promotion_planner.dart';
import 'package:tark/feature/room/domain/service/room_transport_planner.dart';

void main() {
  RoomMemberId member(String suffix) => RoomMemberId(suffix.padLeft(24, '0'));

  RoomTransportCandidate candidate(
    String id, {
    bool canHostHotspot = true,
    bool backgroundReady = true,
    int batteryPercent = 80,
    bool prefersHotspotHost = false,
  }) => RoomTransportCandidate(
    memberId: member(id),
    canHostHotspot: canHostHotspot,
    bluetoothSupported: true,
    backgroundReady: backgroundReady,
    batteryPercent: batteryPercent,
    prefersHotspotHost: prefersHotspotHost,
  );

  RoomCarrierPromotionDecision decide({
    RoomCarrierDurability durability = RoomCarrierDurability.borrowed,
    List<RoomTransportCandidate>? candidates,
    int currentGeneration = 0,
    Duration carrierUpFor = const Duration(seconds: 30),
    int peersPresent = 1,
    int? promotionPlannedForGeneration,
  }) => RoomCarrierPromotionPlanner.decide(
    RoomCarrierPromotionEnvironment(
      durability: durability,
      candidates: candidates ?? [candidate('a'), candidate('b')],
      currentGeneration: currentGeneration,
      carrierUpFor: carrierUpFor,
      peersPresent: peersPresent,
      promotionPlannedForGeneration: promotionPlannedForGeneration,
    ),
  );

  group('carrier durability', () {
    test('plain Wi-Fi is borrowed — it belongs to somebody else', () {
      expect(
        RoomCarrierPromotionPlanner.durabilityOf(RoomTransportKind.sharedLan),
        RoomCarrierDurability.borrowed,
      );
    });

    test('a hotspot and Bluetooth are owned — they travel with the group', () {
      expect(
        RoomCarrierPromotionPlanner.durabilityOf(RoomTransportKind.hotspot),
        RoomCarrierDurability.owned,
      );
      expect(
        RoomCarrierPromotionPlanner.durabilityOf(RoomTransportKind.bluetooth),
        RoomCarrierDurability.owned,
      );
    });

    test('the guest link is never promoted — a browser cannot follow', () {
      // Its LAN is as borrowed as any other, but moving would strand the one
      // participant the mode exists for.
      expect(
        RoomCarrierPromotionPlanner.durabilityOf(RoomTransportKind.guest),
        RoomCarrierDurability.owned,
      );
    });
  });

  group('promoting off a borrowed carrier', () {
    test('a borrowed carrier with an electable host is promoted', () {
      final decision = decide();
      expect(decision.shouldPromote, isTrue);
      expect(decision.reason, RoomCarrierPromotionReason.borrowedCarrier);
      expect(decision.generation, 1);
      expect(decision.host, isNotNull);
    });

    test('the generation always advances past the current one', () {
      expect(decide(currentGeneration: 7).generation, 8);
    });

    test('an owned carrier is left alone', () {
      // Re-electing a host that is already hosting would tear down a working
      // link to rebuild the identical one.
      final decision = decide(durability: RoomCarrierDurability.owned);
      expect(decision.shouldPromote, isFalse);
      expect(decision.reason, RoomCarrierPromotionReason.alreadyOwned);
    });

    test('a carrier that has just come up is given time to settle', () {
      final decision = decide(carrierUpFor: const Duration(seconds: 2));
      expect(decision.shouldPromote, isFalse);
      expect(decision.reason, RoomCarrierPromotionReason.settling);
    });

    test('the settle window is the boundary, not an approximation', () {
      expect(
        decide(
          carrierUpFor:
              RoomCarrierPromotionPlanner.settleWindow -
              const Duration(milliseconds: 1),
        ).shouldPromote,
        isFalse,
      );
      expect(
        decide(
          carrierUpFor: RoomCarrierPromotionPlanner.settleWindow,
        ).shouldPromote,
        isTrue,
      );
    });

    test('a Room of one is not moved anywhere', () {
      // Moving the carrier out from under a group that has not arrived yet is
      // strictly worse than waiting for them on the network they are joining.
      final decision = decide(peersPresent: 0);
      expect(decision.shouldPromote, isFalse);
      expect(decision.reason, RoomCarrierPromotionReason.waitingForPeers);
    });

    test('staying on a borrowed network beats moving to no network', () {
      final decision = decide(
        candidates: [
          candidate('a', canHostHotspot: false),
          candidate('b', canHostHotspot: false),
        ],
      );
      expect(decision.shouldPromote, isFalse);
      expect(decision.reason, RoomCarrierPromotionReason.noEligibleHost);
    });

    test('a phone that cannot run in the background is not elected', () {
      // It would drop the whole Room's network the moment the screen locked.
      final decision = decide(
        candidates: [
          candidate('a', backgroundReady: false),
          candidate('b', backgroundReady: false),
        ],
      );
      expect(decision.reason, RoomCarrierPromotionReason.noEligibleHost);
    });

    test('a decision already taken is not retaken', () {
      // Otherwise every capability heartbeat would restart the handover.
      final decision = decide(promotionPlannedForGeneration: 1);
      expect(decision.shouldPromote, isFalse);
      expect(decision.reason, RoomCarrierPromotionReason.alreadyPlanned);
    });
  });

  group('who hosts', () {
    test('the election matches the failover election exactly', () {
      // A group that promotes and then loses its host must not discover that
      // the two elections disagree, so both go through RoomTransportPlanner.
      final candidates = [
        candidate('a', batteryPercent: 40),
        candidate('b', batteryPercent: 90),
        candidate('c', batteryPercent: 60),
      ];
      final promotion = decide(candidates: candidates);
      final failover = RoomTransportPlanner.plan(
        RoomTransportEnvironment(
          sharedLanUsable: false,
          candidates: candidates,
          epoch: 1,
        ),
      );
      expect(promotion.host, failover.hotspotHost);
      expect(promotion.host, member('b'));
    });

    test('a volunteer outranks a fuller battery', () {
      final decision = decide(
        candidates: [
          candidate('a', batteryPercent: 95),
          candidate('b', batteryPercent: 20, prefersHotspotHost: true),
        ],
      );
      expect(decision.host, member('b'));
    });

    test('localIsHost identifies the device that has to do the work', () {
      final decision = decide(
        candidates: [candidate('a', batteryPercent: 90), candidate('b')],
      );
      expect(decision.localIsHost(member('a')), isTrue);
      expect(decision.localIsHost(member('b')), isFalse);
    });
  });
}
