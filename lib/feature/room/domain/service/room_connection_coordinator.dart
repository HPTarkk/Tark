import '../entity/room.dart';
import 'room_transport_planner.dart';

/// The user-visible lifecycle of one attempt to make a durable Room live.
///
/// This deliberately sits above Wi-Fi, hotspot and Bluetooth implementations.
/// A Room member pressing Start asks this coordinator for a plan; it never
/// directly starts a hotspot. That one rule prevents two local UI paths from
/// independently becoming host for the same Room epoch.
enum RoomConnectionPhase {
  idle,
  preparing,
  waitingForPeerProof,
  connected,
  failed,
  cancelled,
}

/// Why a connection attempt stopped before becoming live.
enum RoomConnectionFailure { noEligibleTransport, cancelled, staleEpoch }

/// Immutable snapshot consumed by Room UI and transport adapters.
final class RoomConnectionState {
  const RoomConnectionState({
    required this.epoch,
    required this.phase,
    required this.startRequestedBy,
    this.plan,
    this.failure,
  });

  const RoomConnectionState.idle()
    : epoch = 0,
      phase = RoomConnectionPhase.idle,
      startRequestedBy = const {},
      plan = null,
      failure = null;

  /// Monotonically increasing Room-local epoch. Transport callbacks must echo
  /// this value; an old callback is never allowed to revive an old attempt.
  final int epoch;
  final RoomConnectionPhase phase;
  final Set<RoomMemberId> startRequestedBy;
  final RoomTransportPlan? plan;
  final RoomConnectionFailure? failure;

  bool get isTerminal =>
      phase == RoomConnectionPhase.connected ||
      phase == RoomConnectionPhase.failed ||
      phase == RoomConnectionPhase.cancelled;

  bool get isActive =>
      phase == RoomConnectionPhase.preparing ||
      phase == RoomConnectionPhase.waitingForPeerProof;
}

/// Room-scoped authority for Start intent and transport-plan adoption.
///
/// The coordinator is intentionally pure/stateful rather than owning a radio.
/// Native Bluetooth/Wi-Fi code reports facts to it; only the elected transport
/// adapter acts on its emitted [RoomTransportPlan]. This keeps membership UI,
/// transport setup and live audio from racing to invent their own role.
final class RoomConnectionCoordinator {
  RoomConnectionCoordinator({RoomConnectionState? initialState})
    : _state = initialState ?? const RoomConnectionState.idle();

  RoomConnectionState _state;

  RoomConnectionState get state => _state;

  /// Records a Start tap and elects exactly one deterministic plan.
  ///
  /// Repeated taps during an active attempt return the same state/epoch. A
  /// transport adapter must therefore never receive a second create request
  /// merely because the other phone (or the same user) tapped Start again.
  RoomConnectionState requestStart({
    required RoomMemberId requester,
    required bool sharedLanUsable,
    required List<RoomTransportCandidate> candidates,
  }) {
    final current = _state;
    if (current.isActive || current.phase == RoomConnectionPhase.connected) {
      _state = RoomConnectionState(
        epoch: current.epoch,
        phase: current.phase,
        startRequestedBy: {...current.startRequestedBy, requester},
        plan: current.plan,
        failure: current.failure,
      );
      return _state;
    }

    final epoch = current.epoch + 1;
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: sharedLanUsable,
        candidates: candidates,
        epoch: epoch,
      ),
    );
    _state = RoomConnectionState(
      epoch: epoch,
      phase: plan.isUsable
          ? RoomConnectionPhase.preparing
          : RoomConnectionPhase.failed,
      startRequestedBy: {requester},
      plan: plan,
      failure: plan.isUsable ? null : RoomConnectionFailure.noEligibleTransport,
    );
    return _state;
  }

  /// Records the selected-network/binding half of readiness.
  ///
  /// This does not mark a Room connected. A peer must still prove it reached
  /// the same Room epoch through [reportPeerProof].
  RoomConnectionState reportTransportReady({required int epoch}) {
    if (epoch != _state.epoch || !_state.isActive) return _state;
    _state = RoomConnectionState(
      epoch: _state.epoch,
      phase: RoomConnectionPhase.waitingForPeerProof,
      startRequestedBy: _state.startRequestedBy,
      plan: _state.plan,
    );
    return _state;
  }

  /// The only transition that is allowed to publish a live connection.
  ///
  /// Call this after authenticated Room hello/ack, not after a QR scan, AP
  /// creation, Wi-Fi association or a local UDP bind.
  RoomConnectionState reportPeerProof({required int epoch}) {
    if (epoch != _state.epoch ||
        _state.phase != RoomConnectionPhase.waitingForPeerProof) {
      return _state;
    }
    _state = RoomConnectionState(
      epoch: _state.epoch,
      phase: RoomConnectionPhase.connected,
      startRequestedBy: _state.startRequestedBy,
      plan: _state.plan,
    );
    return _state;
  }

  /// Cancelling owns one epoch only. A delayed native completion from that
  /// epoch is ignored by [reportTransportReady]/[reportPeerProof].
  RoomConnectionState cancel({required int epoch}) {
    if (epoch != _state.epoch || !_state.isActive) return _state;
    _state = RoomConnectionState(
      epoch: _state.epoch,
      phase: RoomConnectionPhase.cancelled,
      startRequestedBy: _state.startRequestedBy,
      plan: _state.plan,
      failure: RoomConnectionFailure.cancelled,
    );
    return _state;
  }
}
