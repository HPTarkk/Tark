import '../entity/room.dart';
import 'room_failover_controller.dart';
import 'room_failover_runtime.dart';
import 'room_failover_transport_orchestrator.dart';
import 'room_peer_member_binding_registry.dart';
import 'room_transport_candidate_registry.dart';
import 'room_transport_capability_observer.dart';

/// Session-scoped composition for verified transport capability evidence and
/// controlled Room failover.
///
/// This keeps the security/lifecycle rules for #48/#51 in one place without
/// teaching the Room domain about Wi-Fi addresses, device ids, platform
/// channels, or packet formats:
///
/// * a remote transport peer must first be bound to an already-admitted durable
///   RoomMemberId;
/// * only capability evidence from the active attachment generation is kept;
/// * stale/expired/unknown evidence fails closed before host election;
/// * a replacement attachment invalidates every old peer binding/candidate;
/// * Room identity and durable membership never come from transport evidence.
///
/// A transport adapter remains responsible for proving which live peer key maps
/// to which admitted member and for supplying the non-secret capability fields.
/// This runtime then owns the safe path from that proof to election/failover.
final class RoomCapabilityFailoverRuntime {
  RoomCapabilityFailoverRuntime({
    required this.orchestrator,
    Duration candidateFreshFor = const Duration(seconds: 10),
    int maxCandidates = 12,
  }) : bindings = RoomPeerMemberBindingRegistry(
         members: orchestrator.runtime.session.state.memberIds.map(
           RoomMemberId.new,
         ),
       ),
       candidates = RoomTransportCandidateRegistry(
         freshFor: candidateFreshFor,
         maxCandidates: maxCandidates,
       ) {
    observer = RoomTransportCapabilityObserver(
      bindings: bindings,
      candidates: candidates,
    );
  }

  final RoomFailoverTransportOrchestrator orchestrator;
  final RoomPeerMemberBindingRegistry bindings;
  final RoomTransportCandidateRegistry candidates;
  late final RoomTransportCapabilityObserver observer;

  int get attachmentGeneration =>
      orchestrator.runtime.session.attachmentGeneration;

  RoomMemberId get localMemberId =>
      RoomMemberId(orchestrator.runtime.session.state.localMemberId);

  /// Refreshes the durable membership allow-list after a canonical membership
  /// mutation. Removed members lose their peer binding immediately.
  void replaceMembers(Iterable<RoomMemberId> members) {
    bindings.replaceMembers(members);
    final allowed = members.toSet();
    final snapshot = candidates.snapshot(
      now: DateTime.now().toUtc(),
      attachmentGeneration: attachmentGeneration,
    );
    for (final candidate in snapshot) {
      if (!allowed.contains(candidate.memberId)) {
        candidates.remove(candidate.memberId);
      }
    }
  }

  /// Binds an opaque live transport peer to a member that has already passed
  /// canonical Room membership authorization.
  bool bindPeer({required String peerKey, required RoomMemberId memberId}) =>
      bindings.bind(
        peerKey: peerKey,
        memberId: memberId,
        attachmentGeneration: attachmentGeneration,
      );

  bool observePeer({
    required String peerKey,
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    bool prefersHotspotHost = false,
  }) => observer.observePeer(
    peerKey: peerKey,
    canHostHotspot: canHostHotspot,
    bluetoothSupported: bluetoothSupported,
    backgroundReady: backgroundReady,
    batteryPercent: batteryPercent,
    at: at,
    attachmentGeneration: attachmentGeneration,
    prefersHotspotHost: prefersHotspotHost,
  );

  void observeLocal({
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    bool prefersHotspotHost = false,
  }) {
    observer.observeLocal(
      memberId: localMemberId,
      canHostHotspot: canHostHotspot,
      bluetoothSupported: bluetoothSupported,
      backgroundReady: backgroundReady,
      batteryPercent: batteryPercent,
      at: at,
      attachmentGeneration: attachmentGeneration,
      prefersHotspotHost: prefersHotspotHost,
    );
  }

  /// Starts controlled failover from only the fresh verified evidence of the
  /// attachment that is failing. Once a replacement generation is created, all
  /// old peer bindings/candidates are invalidated immediately; the new
  /// attachment must establish its own evidence before a later election.
  Future<RoomFailoverAttempt?> beginFailover({
    required bool sharedLanUsable,
    required RoomFailoverReason reason,
    required DateTime now,
  }) async {
    final previousGeneration = attachmentGeneration;
    final attempt = await orchestrator.beginFromRegistry(
      sharedLanUsable: sharedLanUsable,
      candidates: candidates,
      attachmentGeneration: previousGeneration,
      now: now,
      reason: reason,
    );
    final nextGeneration = attempt?.attachmentGeneration;
    if (nextGeneration != null && nextGeneration != previousGeneration) {
      observer.replaceAttachment(nextGeneration);
    }
    return attempt;
  }

  void removePeer(String peerKey) => observer.removePeer(
    peerKey,
    attachmentGeneration: attachmentGeneration,
  );

  void removeMember(RoomMemberId memberId) => observer.removeMember(memberId);

  void dispose() {
    candidates.dispose();
    bindings.dispose();
  }
}
