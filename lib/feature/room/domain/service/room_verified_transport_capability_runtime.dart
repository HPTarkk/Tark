import '../entity/room.dart';
import 'room_capability_failover_runtime.dart';
import 'room_failover_controller.dart';
import 'room_failover_runtime.dart';
import 'room_member_transport_proof_binding_authority.dart';

/// Security composition boundary between live transport identity and Room
/// capability/failover planning.
///
/// The proof authority deliberately shares the exact peer/member binding
/// registry owned by [RoomCapabilityFailoverRuntime]. A route therefore cannot
/// become a planner candidate through this surface until an issuer-certified,
/// challenge-bound member proof has verified for that same carrier-observed
/// route and current attachment generation.
///
/// This class intentionally exposes no direct `peerKey -> RoomMemberId` binding
/// operation. Transport metadata (IP, sender id, SSID, display/device name,
/// channel id) is not Room identity and never becomes authority here.
final class RoomVerifiedTransportCapabilityRuntime {
  RoomVerifiedTransportCapabilityRuntime({
    required this.capability,
    required List<int> expectedIssuerPublicKey,
  }) : proofs = RoomMemberTransportProofBindingAuthority(
         roomId: _roomId(capability),
         bindings: capability.bindings,
         expectedIssuerPublicKey: expectedIssuerPublicKey,
       );

  final RoomCapabilityFailoverRuntime capability;
  final RoomMemberTransportProofBindingAuthority proofs;

  int get attachmentGeneration => capability.attachmentGeneration;

  bool observeChallenge({
    required String peerKey,
    required int token,
    required int sessionEpoch,
    required DateTime at,
  }) => proofs.observeChallenge(
    peerKey: peerKey,
    token: token,
    sessionEpoch: sessionEpoch,
    attachmentGeneration: attachmentGeneration,
    at: at,
  );

  /// Returns the member the route was bound to, or null when nothing bound.
  Future<RoomMemberId?> verifyAndBind({
    required String peerKey,
    required String encodedProof,
    required DateTime at,
  }) => proofs.verifyAndBind(
    peerKey: peerKey,
    encodedProof: encodedProof,
    attachmentGeneration: attachmentGeneration,
    at: at,
  );

  bool observePeer({
    required String peerKey,
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    bool prefersHotspotHost = false,
  }) => capability.observePeer(
    peerKey: peerKey,
    canHostHotspot: canHostHotspot,
    bluetoothSupported: bluetoothSupported,
    backgroundReady: backgroundReady,
    batteryPercent: batteryPercent,
    at: at,
    prefersHotspotHost: prefersHotspotHost,
  );

  void observeLocal({
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    bool prefersHotspotHost = false,
  }) => capability.observeLocal(
    canHostHotspot: canHostHotspot,
    bluetoothSupported: bluetoothSupported,
    backgroundReady: backgroundReady,
    batteryPercent: batteryPercent,
    at: at,
    prefersHotspotHost: prefersHotspotHost,
  );

  Future<RoomFailoverAttempt?> beginFailover({
    required bool sharedLanUsable,
    required RoomFailoverReason reason,
    required DateTime now,
  }) async {
    final previousGeneration = attachmentGeneration;
    final attempt = await capability.beginFailover(
      sharedLanUsable: sharedLanUsable,
      reason: reason,
      now: now,
    );
    final nextGeneration = attempt?.attachmentGeneration;
    if (nextGeneration != null && nextGeneration != previousGeneration) {
      // capability.beginFailover already advances its observer/candidates.
      // Advance the proof authority too so delayed proof responses from the
      // replaced attachment cannot recreate an old route binding.
      proofs.replaceAttachment(nextGeneration);
    }
    return attempt;
  }

  void replaceMembers(Iterable<RoomMemberId> members) {
    capability.replaceMembers(members);
  }

  void removePeer(String peerKey) {
    proofs.removePeer(peerKey);
    capability.removePeer(peerKey);
  }

  void removeMember(RoomMemberId memberId) {
    capability.removeMember(memberId);
  }

  void dispose() {
    proofs.dispose();
    capability.dispose();
  }

  static RoomId _roomId(RoomCapabilityFailoverRuntime capability) {
    final parsed = RoomId.parse(
      capability.orchestrator.runtime.session.state.roomId,
    );
    if (parsed == null) {
      throw StateError(
        'Verified transport identity requires a canonical durable RoomId.',
      );
    }
    return parsed;
  }
}
