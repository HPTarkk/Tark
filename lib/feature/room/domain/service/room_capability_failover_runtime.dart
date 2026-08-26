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
/// Remote transport evidence never creates Room identity or membership. A peer
/// must first be bound to an already-admitted durable RoomMemberId, evidence is
/// scoped to the active attachment generation, and replacement invalidates old
/// bindings/candidates before another election can use them.
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
    _members = orchestrator.runtime.session.state.memberIds
        .map(RoomMemberId.new)
        .toSet();
    observer = RoomTransportCapabilityObserver(
      bindings: bindings,
      candidates: candidates,
    );
  }

  final RoomFailoverTransportOrchestrator orchestrator;
  final RoomPeerMemberBindingRegistry bindings;
  final RoomTransportCandidateRegistry candidates;
  late final RoomTransportCapabilityObserver observer;
  late Set<RoomMemberId> _members;

  int get attachmentGeneration =>
      orchestrator.runtime.session.attachmentGeneration;

  RoomMemberId get localMemberId =>
      RoomMemberId(orchestrator.runtime.session.state.localMemberId);

  /// Refreshes the canonical membership allow-list. Removed members lose both
  /// their transport binding and candidate evidence immediately.
  void replaceMembers(Iterable<RoomMemberId> members) {
    final next = members.toSet();
    for (final removed in _members.difference(next)) {
      observer.removeMember(removed);
    }
    bindings.replaceMembers(next);
    _members = next;
  }

  /// Binds an opaque live transport peer only to an already-admitted member.
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

  /// Starts failover from the fresh verified evidence of the attachment that is
  /// failing, then invalidates old evidence as soon as a replacement generation
  /// is created.
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

  void removePeer(String peerKey) =>
      observer.removePeer(peerKey, attachmentGeneration: attachmentGeneration);

  void removeMember(RoomMemberId memberId) {
    observer.removeMember(memberId);
    _members.remove(memberId);
  }

  void dispose() {
    candidates.dispose();
    bindings.dispose();
    _members.clear();
  }
}
