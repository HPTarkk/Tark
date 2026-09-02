import '../entity/room.dart';
import '../entity/room_carrier.dart';
import 'room_transport_planner.dart';

/// Why a Room is, or is not, being moved off the network it is currently on.
enum RoomCarrierPromotionReason {
  /// The carrier is borrowed and a member can raise one the Room owns. The
  /// only reason that produces a promotion.
  borrowedCarrier,

  /// Already on a carrier the Room owns. Nothing to do — and nothing *should*
  /// be done: re-electing a host that is already hosting would tear down a
  /// working link to rebuild the same one.
  alreadyOwned,

  /// Borrowed, but nobody present can raise an access point. Staying is
  /// strictly better than leaving: a borrowed network that works today beats
  /// no network at all, and the group is told the truth rather than moved
  /// somewhere worse.
  noEligibleHost,

  /// The current carrier has not been up long enough to be worth leaving.
  /// Promoting into a link that is still settling would fight the session's
  /// own start-up, and the first seconds are when peers are still arriving.
  settling,

  /// A promotion for this generation has already been decided. Re-deciding
  /// would restart the handover every time a peer's capability heartbeat
  /// arrived.
  alreadyPlanned,

  /// Not enough of the Room is here yet. Moving a group of one is pointless
  /// and, worse, it moves the carrier out from under everyone still arriving
  /// on the borrowed one.
  waitingForPeers,
}

/// What to do about the Room's current carrier.
final class RoomCarrierPromotionDecision {
  const RoomCarrierPromotionDecision({
    required this.reason,
    required this.generation,
    this.host,
  });

  final RoomCarrierPromotionReason reason;

  /// The carrier this decision would move the Room to. Only meaningful when
  /// [shouldPromote].
  final int generation;

  /// The member elected to raise the access point.
  final RoomMemberId? host;

  bool get shouldPromote =>
      reason == RoomCarrierPromotionReason.borrowedCarrier && host != null;

  /// Whether this device is the one that has to do the work.
  bool localIsHost(RoomMemberId localMemberId) => host == localMemberId;
}

/// Everything the promotion decision is allowed to reason from.
final class RoomCarrierPromotionEnvironment {
  const RoomCarrierPromotionEnvironment({
    required this.durability,
    required this.candidates,
    required this.currentGeneration,
    required this.carrierUpFor,
    required this.peersPresent,
    this.promotionPlannedForGeneration,
  });

  final RoomCarrierDurability durability;

  /// Members whose capability evidence has been verified and bound to a
  /// durable RoomMemberId. Unverified observations must never reach here — an
  /// unauthenticated peer claiming `canHostHotspot` could otherwise nominate
  /// itself to run the whole Room's network.
  final List<RoomTransportCandidate> candidates;

  final int currentGeneration;

  /// How long the current carrier has been up.
  final Duration carrierUpFor;

  /// How many other members are actually on the channel right now.
  final int peersPresent;

  /// The generation a promotion has already been planned for, if any.
  final int? promotionPlannedForGeneration;
}

/// Decides whether to move a Room off a borrowed network before it disappears.
///
/// Pure and synchronous, like [RoomTransportPlanner], so the whole policy is
/// testable without a radio. It answers one question — *should we move, and
/// who hosts* — and nothing about how the move is carried out.
///
/// ## Why this runs while everything is working
///
/// Every other transport decision in this app is a response to something
/// breaking. This one is the opposite, and deliberately so. The scenario it
/// exists for is two people setting up at home on the house Wi-Fi and then
/// riding away: the link is flawless right up to the moment it is gone, and by
/// then there is no path left over which to agree on a replacement. So the
/// replacement is arranged in advance, in the driveway, while both phones are
/// a metre apart with a working network between them — which is the best
/// conditions a handover will ever get, instead of the worst.
abstract final class RoomCarrierPromotionPlanner {
  /// How long a borrowed carrier must have been up before it is worth leaving.
  ///
  /// Long enough for the session to finish opening and for the other phones to
  /// appear, short enough that it is still comfortably "while you are getting
  /// ready" rather than "somewhere along the first mile".
  static const settleWindow = Duration(seconds: 12);

  static RoomCarrierPromotionDecision decide(
    RoomCarrierPromotionEnvironment environment,
  ) {
    final generation = environment.currentGeneration + 1;

    if (!environment.durability.isBorrowed) {
      return RoomCarrierPromotionDecision(
        reason: RoomCarrierPromotionReason.alreadyOwned,
        generation: generation,
      );
    }
    if (environment.promotionPlannedForGeneration == generation) {
      return RoomCarrierPromotionDecision(
        reason: RoomCarrierPromotionReason.alreadyPlanned,
        generation: generation,
      );
    }
    if (environment.peersPresent < 1) {
      return RoomCarrierPromotionDecision(
        reason: RoomCarrierPromotionReason.waitingForPeers,
        generation: generation,
      );
    }
    if (environment.carrierUpFor < settleWindow) {
      return RoomCarrierPromotionDecision(
        reason: RoomCarrierPromotionReason.settling,
        generation: generation,
      );
    }

    // Reuses the existing election rather than inventing a second one, so the
    // host chosen here and the host chosen by a later failover are picked by
    // the same rule — a group that promotes and then loses its host must not
    // discover the two disagree.
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: false,
        candidates: environment.candidates,
        epoch: generation,
      ),
    );
    final host = plan.kind == RoomTransportKind.hotspot
        ? plan.hotspotHost
        : null;
    if (host == null) {
      return RoomCarrierPromotionDecision(
        reason: RoomCarrierPromotionReason.noEligibleHost,
        generation: generation,
      );
    }
    return RoomCarrierPromotionDecision(
      reason: RoomCarrierPromotionReason.borrowedCarrier,
      generation: generation,
      host: host,
    );
  }

  /// Classifies the carrier a mode is running over.
  ///
  /// Plain Wi-Fi is the borrowed one: it means an access point that neither
  /// phone controls and neither phone can take with it. A hotspot is owned by
  /// definition — somebody in the Room is the access point — and Bluetooth
  /// involves no infrastructure at all. The guest link is a browser on the
  /// same LAN, so it inherits that LAN's fate and is borrowed too, but it is
  /// never promoted: a browser cannot follow a phone onto a hotspot, and
  /// moving would strand the very participant the mode exists for.
  static RoomCarrierDurability durabilityOf(RoomTransportKind? kind) =>
      switch (kind) {
        RoomTransportKind.hotspot => RoomCarrierDurability.owned,
        RoomTransportKind.bluetooth => RoomCarrierDurability.owned,
        RoomTransportKind.sharedLan => RoomCarrierDurability.borrowed,
        RoomTransportKind.guest => RoomCarrierDurability.owned,
        null => RoomCarrierDurability.owned,
      };
}
