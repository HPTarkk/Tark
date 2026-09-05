import '../entity/room.dart';

enum RoomTransportKind { sharedLan, hotspot, bluetooth, guest }

enum RoomTransportPlanReason {
  usableSharedLan,
  deterministicHotspotHost,
  preferredHotspotHost,
  bluetoothFallback,
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
}

final class RoomTransportEnvironment {
  const RoomTransportEnvironment({
    required this.sharedLanUsable,
    required this.candidates,
    required this.epoch,
    this.guestExplicitlySelected = false,
  }) : assert(epoch >= 0);

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
          (candidate) => candidate.canHostHotspot && candidate.backgroundReady,
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

    if (environment.candidates.any(
      (candidate) => candidate.bluetoothSupported,
    )) {
      return RoomTransportPlan(
        epoch: environment.epoch,
        kind: RoomTransportKind.bluetooth,
        reason: RoomTransportPlanReason.bluetoothFallback,
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
        final battery = b.batteryPercent.compareTo(a.batteryPercent);
        if (battery != 0) return battery;
        return a.memberId.value.compareTo(b.memberId.value);
      });
    return ordered.first;
  }
}
