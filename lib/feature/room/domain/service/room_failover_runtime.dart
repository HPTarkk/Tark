import '../entity/transport_attachment.dart';
import 'room_failover_controller.dart';
import 'room_session_runtime.dart';
import 'room_transport_planner.dart';

/// One accepted failover decision paired with the attachment generation it
/// created. The two epochs intentionally stay separate: [failoverEpoch]
/// rejects stale election results while [attachmentGeneration] rejects stale
/// native/socket callbacks from an attachment that has already been replaced.
class RoomFailoverAttempt {
  const RoomFailoverAttempt({
    required this.decision,
    required this.attachmentGeneration,
  });

  final RoomFailoverDecision decision;

  /// Null when no usable replacement transport exists. The logical Room stays
  /// present in recovery and the current failed attachment remains visible.
  final int? attachmentGeneration;
}

/// Application seam that applies [RoomFailoverController] decisions to a
/// transport-independent [RoomSessionRuntime].
///
/// It deliberately does not know how Wi-Fi, LocalOnlyHotspot, Bluetooth or
/// WebRTC are started. A concrete adapter performs that work after [begin] (or
/// [adopt]) returns and must present both the failover epoch and attachment
/// generation back on callbacks. Only callbacks matching both are accepted.
///
/// This is the split-brain boundary for #51: an old host returning, a delayed
/// native callback, or a simultaneous election can never overwrite the newer
/// attachment. RoomId, membership and mute state are owned by [session] and are
/// never inputs to host election.
class RoomFailoverRuntime {
  RoomFailoverRuntime({
    required this.session,
    RoomFailoverController? controller,
  }) : controller = controller ?? RoomFailoverController();

  final RoomSessionRuntime session;
  final RoomFailoverController controller;

  int? _activeFailoverEpoch;
  int? _activeAttachmentGeneration;

  int? get activeFailoverEpoch => _activeFailoverEpoch;
  int? get activeAttachmentGeneration => _activeAttachmentGeneration;

  Future<RoomFailoverAttempt?> begin({
    required bool sharedLanUsable,
    required List<RoomTransportCandidate> candidates,
    required RoomFailoverReason reason,
  }) async {
    final decision = controller.failover(
      sharedLanUsable: sharedLanUsable,
      candidates: candidates,
      reason: reason,
    );
    if (decision == null) return null;
    return _apply(decision);
  }

  /// Adopts a strictly newer election result from another participant. Older
  /// or same-epoch results are ignored by [RoomFailoverController], preventing
  /// simultaneous candidates from repeatedly replacing each other.
  Future<RoomFailoverAttempt?> adopt(RoomFailoverDecision decision) async {
    if (!controller.adopt(decision)) return null;
    return _apply(decision);
  }

  Future<RoomFailoverAttempt> _apply(RoomFailoverDecision decision) async {
    _activeFailoverEpoch = decision.epoch;
    final kind = _transportKind(decision.plan.kind);
    if (kind == null) {
      _activeAttachmentGeneration = null;
      session.failed(
        generation: session.attachmentGeneration,
        reason: 'failover_no_eligible_transport',
      );
      return RoomFailoverAttempt(
        decision: decision,
        attachmentGeneration: null,
      );
    }

    final generation = await session.replaceTransport(
      kind: kind,
      role: _roleFor(decision.plan),
      reason: 'failover_${decision.reason.name}',
    );
    _activeAttachmentGeneration = generation;
    return RoomFailoverAttempt(
      decision: decision,
      attachmentGeneration: generation,
    );
  }

  /// True only when both application election and native attachment generation
  /// still identify the active replacement. This must gate every callback from
  /// a concrete transport adapter.
  bool accepts({
    required int failoverEpoch,
    required int attachmentGeneration,
  }) {
    return !controller.isCancelled &&
        controller.acceptsEpoch(failoverEpoch) &&
        _activeFailoverEpoch == failoverEpoch &&
        _activeAttachmentGeneration == attachmentGeneration &&
        session.attachmentGeneration == attachmentGeneration;
  }

  bool ready({
    required int failoverEpoch,
    required int attachmentGeneration,
    String? role,
  }) {
    if (!accepts(
      failoverEpoch: failoverEpoch,
      attachmentGeneration: attachmentGeneration,
    )) {
      return false;
    }
    session.ready(generation: attachmentGeneration, role: role);
    return true;
  }

  bool degraded({
    required int failoverEpoch,
    required int attachmentGeneration,
    String? reason,
  }) {
    if (!accepts(
      failoverEpoch: failoverEpoch,
      attachmentGeneration: attachmentGeneration,
    )) {
      return false;
    }
    session.degraded(generation: attachmentGeneration, reason: reason);
    return true;
  }

  bool failed({
    required int failoverEpoch,
    required int attachmentGeneration,
    String? reason,
  }) {
    if (!accepts(
      failoverEpoch: failoverEpoch,
      attachmentGeneration: attachmentGeneration,
    )) {
      return false;
    }
    session.failed(generation: attachmentGeneration, reason: reason);
    return true;
  }

  /// Ends only this failover lifetime. It deliberately does not call
  /// [RoomSessionRuntime.leave]; cancelling recovery is not leaving the Room.
  void cancel() {
    controller.cancel();
    _activeFailoverEpoch = null;
    _activeAttachmentGeneration = null;
  }

  String? _roleFor(RoomTransportPlan plan) {
    if (plan.kind != RoomTransportKind.hotspot) return 'peer';
    final elected = plan.hotspotHost?.value;
    return elected == session.state.localMemberId ? 'host' : 'joiner';
  }

  static TransportKind? _transportKind(RoomTransportKind? kind) => switch (kind) {
    RoomTransportKind.sharedLan => TransportKind.wifi,
    RoomTransportKind.hotspot => TransportKind.hotspot,
    RoomTransportKind.bluetooth => TransportKind.bluetooth,
    RoomTransportKind.guest => TransportKind.webrtc,
    null => null,
  };
}
