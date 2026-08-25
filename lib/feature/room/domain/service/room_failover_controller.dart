import '../entity/room.dart';
import 'room_transport_planner.dart';

enum RoomFailoverReason {
  hostLost,
  manualRetry,
  transportFailed,
}

class RoomFailoverDecision {
  const RoomFailoverDecision({
    required this.epoch,
    required this.plan,
    required this.reason,
    required this.requiresUserRescan,
  });

  final int epoch;
  final RoomTransportPlan plan;
  final RoomFailoverReason reason;

  /// Android local-only hotspots rotate credentials when recreated. Peers that
  /// are no longer attached cannot be promised seamless recovery and may need
  /// to scan the newly surfaced bootstrap again.
  final bool requiresUserRescan;
}

/// Small application-domain policy for replacing a failed Room transport host.
///
/// It owns only failover epochs. RoomId, Room ownership and membership are not
/// inputs and therefore cannot be mutated by a transport election. The same
/// candidate snapshot always produces the same host for an epoch through
/// [RoomTransportPlanner], while every accepted failover advances the epoch so
/// callbacks from the previous attachment can be rejected by the caller.
class RoomFailoverController {
  RoomFailoverController({int initialEpoch = 0})
      : assert(initialEpoch >= 0),
        _epoch = initialEpoch;

  int _epoch;
  bool _cancelled = false;
  RoomFailoverDecision? _current;

  int get epoch => _epoch;
  bool get isCancelled => _cancelled;
  RoomFailoverDecision? get current => _current;

  RoomFailoverDecision? failover({
    required bool sharedLanUsable,
    required List<RoomTransportCandidate> candidates,
    required RoomFailoverReason reason,
  }) {
    if (_cancelled) return null;

    final nextEpoch = _epoch + 1;
    final plan = RoomTransportPlanner.plan(
      RoomTransportEnvironment(
        sharedLanUsable: sharedLanUsable,
        candidates: candidates,
        epoch: nextEpoch,
      ),
    );
    final decision = RoomFailoverDecision(
      epoch: nextEpoch,
      plan: plan,
      reason: reason,
      requiresUserRescan: plan.kind == RoomTransportKind.hotspot,
    );
    _epoch = nextEpoch;
    _current = decision;
    return decision;
  }

  /// Application-level stale callback guard. Native/socket generation guards
  /// still apply underneath this one; both must agree before state is adopted.
  bool acceptsEpoch(int callbackEpoch) => !_cancelled && callbackEpoch == _epoch;

  /// A simultaneous election result may arrive after another result for the
  /// same/newer epoch. Only strictly newer decisions can replace current state.
  bool adopt(RoomFailoverDecision decision) {
    if (_cancelled || decision.epoch <= _epoch) return false;
    _epoch = decision.epoch;
    _current = decision;
    return true;
  }

  /// Explicit user cancellation ends this failover lifetime. It does not mean
  /// leaving the durable Room; a new live session creates a new controller.
  void cancel() {
    _cancelled = true;
  }
}
