import '../entity/room.dart';

enum RoomTransportKind { sharedLan, hotspot, guest }

enum RoomTransportPlanReason {
  usableSharedLan,
  deterministicHotspotHost,
  preferredHotspotHost,
  guestExplicit,
  noEligibleTransport,
}

final class RoomTransportCandidate {
  const RoomTransportCandidate({
    required this.memberId,
    required this.canHostHotspot,
    required this.bluetoothSupported,
    required this.backgroundReady,
    required this.batteryPercent,
    this.prefersHotspotHost = false,
    this.hostingAccessPoint = false,
    this.gaveUpMove = false,
    this.memberSince,
  }) : assert(batteryPercent >= 0 && batteryPercent <= 100);

  final RoomMemberId memberId;
  final bool canHostHotspot;
  final bool bluetoothSupported;
  final bool backgroundReady;
  final int batteryPercent;

  /// Policy hint only. It never changes Room ownership or durable membership.
  ///
  /// The creator may receive this hint so the first hotspot choice is stable
  /// and unsurprising, but an ineligible creator is skipped like any other
  /// candidate and verified capability evidence remains authoritative.
  final bool prefersHotspotHost;

  /// Whether this member is holding up the access point the Room is on right
  /// now, as it says itself. A phone on that access point cannot tell it from
  /// a router, so this is how both phones agree on what they are standing on.
  final bool hostingAccessPoint;

  /// Whether this member has just given up on moving the Room to a hotspot,
  /// as it says itself. The other phone stops waiting for it the moment it
  /// hears this, so both show the same "couldn't move" together.
  final bool gaveUpMove;

  /// When this member joined the Room, from the roster both phones share.
  /// The longer-standing member leads a tie, so the two agree without
  /// asking each other.
  final DateTime? memberSince;

  RoomTransportCandidate withMemberSince(DateTime? since) =>
      RoomTransportCandidate(
        memberId: memberId,
        canHostHotspot: canHostHotspot,
        bluetoothSupported: bluetoothSupported,
        backgroundReady: backgroundReady,
        batteryPercent: batteryPercent,
        prefersHotspotHost: prefersHotspotHost,
        hostingAccessPoint: hostingAccessPoint,
        gaveUpMove: gaveUpMove,
        memberSince: since,
      );
}

final class RoomTransportEnvironment {
  const RoomTransportEnvironment({
    required this.sharedLanUsable,
    required this.candidates,
    required this.epoch,
    this.guestExplicitlySelected = false,
    this.bootstrapHotspotHost,
    this.requireBackgroundReady = true,
  }) : assert(epoch >= 0);

  /// Whether a hotspot host must already have its background keep-alive up.
  ///
  /// It must for a Room that is live — a host that Android may freeze in the
  /// background would take the whole group's network with it. Not for a move
  /// made before the channel opens: both phones are open in front of their
  /// people then, and the keep-alive only starts with the channel itself, so
  /// requiring it there made every phone ineligible and the move never ran
  /// (2026-10-15: `election=noEligibleHost` on both phones, both on the house
  /// Wi-Fi, the channel opened over the router).
  final bool requireBackgroundReady;

  /// True only for a peer-proven shared LAN for the current Room/session.
  ///
  /// A Wi-Fi interface being up, two phones reporting Wi-Fi, or even matching
  /// SSIDs are not enough: guest isolation, VPN routing and captive/mesh
  /// policies can still make the peers unreachable. The caller must promote
  /// this bit only from actual bidirectional reachability evidence. That keeps
  /// the high-quality LAN fast path first without ever sending the user to a
  /// "put both phones on the same network" setup flow.
  final bool sharedLanUsable;
  final List<RoomTransportCandidate> candidates;
  final int epoch;
  final bool guestExplicitlySelected;

  /// A pre-existing Room bootstrap side, if the invite/create flow has already
  /// established one.  This is intentionally not a capability claim: it is
  /// only the narrow bridge that lets a joiner adopt the one temporary AP
  /// while no authenticated capability exchange is possible yet.
  final RoomMemberId? bootstrapHotspotHost;
}

final class RoomTransportPlan {
  const RoomTransportPlan({
    required this.epoch,
    required this.kind,
    required this.reason,
    this.hotspotHost,
  });

  final int epoch;
  final RoomTransportKind? kind;
  final RoomTransportPlanReason reason;
  final RoomMemberId? hotspotHost;

  bool get isUsable => kind != null;

  /// Guards application-level adoption against an old simultaneous election.
  bool isNewerThan(int currentEpoch) => epoch > currentEpoch;
}

/// Pure deterministic planner for a live Room transport attachment.
///
/// Room identity and ownership are deliberately absent from the decision. A
/// hotspot host is only the temporary member operating today's transport.
///
/// Planning is intentionally conservative: a peer-proven shared LAN wins the
/// initial plan, otherwise the eligible hotspot host is elected
/// deterministically. This planner is not an opportunistic handover engine — a
/// healthy attachment stays sticky and replacement is owned by the failover /
/// controlled-handover state machines with epoch fencing.
abstract final class RoomTransportPlanner {
  static RoomTransportPlan plan(RoomTransportEnvironment environment) {
    if (environment.guestExplicitlySelected) {
      return RoomTransportPlan(
        epoch: environment.epoch,
        kind: RoomTransportKind.guest,
        reason: RoomTransportPlanReason.guestExplicit,
      );
    }

    if (environment.sharedLanUsable) {
      return RoomTransportPlan(
        epoch: environment.epoch,
        kind: RoomTransportKind.sharedLan,
        reason: RoomTransportPlanReason.usableSharedLan,
      );
    }

    final hotspotCandidates = environment.candidates
        .where(
          (candidate) =>
              candidate.canHostHotspot &&
              (candidate.backgroundReady ||
                  !environment.requireBackgroundReady),
        )
        .toList(growable: false);
    if (hotspotCandidates.isNotEmpty) {
      final elected = _electHotspotHost(hotspotCandidates);
      return RoomTransportPlan(
        epoch: environment.epoch,
        kind: RoomTransportKind.hotspot,
        reason: elected.prefersHotspotHost
            ? RoomTransportPlanReason.preferredHotspotHost
            : RoomTransportPlanReason.deterministicHotspotHost,
        hotspotHost: elected.memberId,
      );
    }

    // Cold-start bootstrap precedes the first signed peer proof, so remote
    // capability is correctly unknown here.  Do not invent it merely to run
    // an election.  When the existing Room flow has a single bootstrap side,
    // both participants instead adopt that same temporary AP; verified
    // capability evidence takes over for later failover/handover.
    final bootstrapHost = environment.bootstrapHotspotHost;
    if (bootstrapHost != null) {
      return RoomTransportPlan(
        epoch: environment.epoch,
        kind: RoomTransportKind.hotspot,
        reason: RoomTransportPlanReason.deterministicHotspotHost,
        hotspotHost: bootstrapHost,
      );
    }

    return RoomTransportPlan(
      epoch: environment.epoch,
      kind: null,
      reason: RoomTransportPlanReason.noEligibleTransport,
    );
  }

  static RoomTransportCandidate _electHotspotHost(
    List<RoomTransportCandidate> candidates,
  ) {
    final ordered = [...candidates]
      ..sort((a, b) {
        if (a.prefersHotspotHost != b.prefersHotspotHost) {
          return a.prefersHotspotHost ? -1 : 1;
        }
        final battery = _batteryBand(b).compareTo(_batteryBand(a));
        if (battery != 0) return battery;
        // Then whoever has been in the Room longer, then the member id: a
        // fixed order both phones compute from the same roster, so a tie can
        // never be broken two ways.
        final since = _compareSince(a.memberSince, b.memberSince);
        if (since != 0) return since;
        return a.memberId.value.compareTo(b.memberId.value);
      });
    return ordered.first;
  }

  /// Battery in bands of twenty points, not exact percent.
  ///
  /// Each phone votes with its own fresh reading and the other phone's last
  /// advertised one. Compared to the percent, a phone that had just ticked
  /// down won the vote on its own screen and lost it on the other, and both
  /// raised an access point (2026-10-16). A band only flips at its edge, so
  /// the two views now agree unless a reading crosses one mid-heartbeat.
  static int _compareSince(DateTime? a, DateTime? b) {
    if (a == null || b == null) return 0;
    return a.compareTo(b);
  }

  static int _batteryBand(RoomTransportCandidate candidate) =>
      candidate.batteryPercent.clamp(0, 99) ~/ 20;
}
