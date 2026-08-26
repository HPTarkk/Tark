import '../entity/room.dart';
import 'room_peer_member_binding_registry.dart';
import 'room_transport_candidate_registry.dart';
import 'room_transport_planner.dart';

/// Safe application seam between transport-level capability evidence and the
/// durable Room transport planner.
///
/// Remote advertisements are keyed by an opaque transport peer key. They are
/// accepted only after [bindings] resolves that peer to a Room member already
/// admitted by canonical membership logic. The advertisement itself therefore
/// never gets to choose which durable member it represents.
final class RoomTransportCapabilityObserver {
  const RoomTransportCapabilityObserver({
    required this.bindings,
    required this.candidates,
  });

  final RoomPeerMemberBindingRegistry bindings;
  final RoomTransportCandidateRegistry candidates;

  /// Records capability evidence for an already-bound remote transport peer.
  /// Unknown peers and stale attachment generations fail closed.
  bool observePeer({
    required String peerKey,
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    required int attachmentGeneration,
    bool prefersHotspotHost = false,
  }) {
    if (batteryPercent < 0 || batteryPercent > 100) return false;
    final memberId = bindings.resolve(
      peerKey,
      attachmentGeneration: attachmentGeneration,
    );
    if (memberId == null) return false;
    candidates.observe(
      RoomTransportCandidate(
        memberId: memberId,
        canHostHotspot: canHostHotspot,
        bluetoothSupported: bluetoothSupported,
        backgroundReady: backgroundReady,
        batteryPercent: batteryPercent,
        prefersHotspotHost: prefersHotspotHost,
      ),
      at: at,
      attachmentGeneration: attachmentGeneration,
    );
    return true;
  }

  /// Local capability does not need a transport-peer binding because the
  /// caller already owns the canonical local Room membership.
  void observeLocal({
    required RoomMemberId memberId,
    required bool canHostHotspot,
    required bool bluetoothSupported,
    required bool backgroundReady,
    required int batteryPercent,
    required DateTime at,
    required int attachmentGeneration,
    bool prefersHotspotHost = false,
  }) {
    candidates.observe(
      RoomTransportCandidate(
        memberId: memberId,
        canHostHotspot: canHostHotspot,
        bluetoothSupported: bluetoothSupported,
        backgroundReady: backgroundReady,
        batteryPercent: batteryPercent,
        prefersHotspotHost: prefersHotspotHost,
      ),
      at: at,
      attachmentGeneration: attachmentGeneration,
    );
  }

  /// Advances both identity and capability evidence together. Old-route
  /// identity and old capability observations cannot bleed into a replacement
  /// transport attachment.
  void replaceAttachment(int attachmentGeneration) {
    bindings.replaceAttachment(attachmentGeneration);
    candidates.replaceAttachment(attachmentGeneration);
  }

  void removePeer(String peerKey, {required int attachmentGeneration}) {
    final memberId = bindings.resolve(
      peerKey,
      attachmentGeneration: attachmentGeneration,
    );
    bindings.removePeer(peerKey);
    if (memberId != null) candidates.remove(memberId);
  }

  void removeMember(RoomMemberId memberId) {
    bindings.removeMember(memberId);
    candidates.remove(memberId);
  }
}
