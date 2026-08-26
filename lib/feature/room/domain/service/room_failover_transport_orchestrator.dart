import 'dart:async';

import 'room_failover_controller.dart';
import 'room_failover_runtime.dart';
import 'room_transport_planner.dart';

/// Concrete lifecycle bridge between Room failover decisions and whichever
/// live transport adapter the application selected.
///
/// The starter owns transport-specific work (Wi-Fi/hotspot/Bluetooth/WebRTC),
/// while this class owns the safety boundary around it: only the current
/// failover epoch + attachment generation may mutate RoomSession state, and
/// every started transport is registered as an attachment-scoped resource so
/// replacement/cancellation cannot leak or resurrect an old host.
class RoomFailoverTransportOrchestrator {
  RoomFailoverTransportOrchestrator({
    required this.runtime,
    required this.startTransport,
  });

  final RoomFailoverRuntime runtime;
  final RoomFailoverTransportStarter startTransport;

  Future<RoomFailoverAttempt?> begin({
    required bool sharedLanUsable,
    required List<RoomTransportCandidate> candidates,
    required RoomFailoverReason reason,
  }) async {
    final attempt = await runtime.begin(
      sharedLanUsable: sharedLanUsable,
      candidates: candidates,
      reason: reason,
    );
    if (attempt == null) return null;
    await _start(attempt);
    return attempt;
  }

  Future<RoomFailoverAttempt?> adopt(RoomFailoverDecision decision) async {
    final attempt = await runtime.adopt(decision);
    if (attempt == null) return null;
    await _start(attempt);
    return attempt;
  }

  Future<void> _start(RoomFailoverAttempt attempt) async {
    final generation = attempt.attachmentGeneration;
    if (generation == null) return;

    final epoch = attempt.decision.epoch;
    final callbacks = RoomFailoverTransportCallbacks(
      ready: ({String? role}) => runtime.ready(
        failoverEpoch: epoch,
        attachmentGeneration: generation,
        role: role,
      ),
      degraded: ({String? reason}) => runtime.degraded(
        failoverEpoch: epoch,
        attachmentGeneration: generation,
        reason: reason,
      ),
      failed: ({String? reason}) => runtime.failed(
        failoverEpoch: epoch,
        attachmentGeneration: generation,
        reason: reason,
      ),
    );

    RoomFailoverTransportHandle handle;
    try {
      handle = await startTransport(
        RoomFailoverTransportContext(attempt: attempt, callbacks: callbacks),
      );
    } catch (_) {
      runtime.failed(
        failoverEpoch: epoch,
        attachmentGeneration: generation,
        reason: 'failover_transport_start_failed',
      );
      return;
    }

    // Starting a native transport may await platform work. A newer failover can
    // win while that await is in flight, so re-check both epochs before taking
    // ownership. A stale handle is disposed immediately and never registered.
    if (!runtime.accepts(
      failoverEpoch: epoch,
      attachmentGeneration: generation,
    )) {
      await handle.dispose();
      return;
    }

    final owned = runtime.session.ownCurrentAttachmentResource(
      generation,
      'failover_transport',
      handle.dispose,
    );
    if (!owned) await handle.dispose();
  }

  /// Cancels only recovery. The durable Room remains present, while the active
  /// replacement transport (if any) is disposed with its attachment resources.
  Future<void> cancel() async {
    final generation = runtime.activeAttachmentGeneration;
    runtime.cancel();
    if (generation != null) {
      await runtime.session.resources.disposeAttachment(generation);
    }
  }
}

typedef RoomFailoverTransportStarter =
    Future<RoomFailoverTransportHandle> Function(
      RoomFailoverTransportContext context,
    );

class RoomFailoverTransportContext {
  const RoomFailoverTransportContext({
    required this.attempt,
    required this.callbacks,
  });

  final RoomFailoverAttempt attempt;
  final RoomFailoverTransportCallbacks callbacks;
}

class RoomFailoverTransportCallbacks {
  const RoomFailoverTransportCallbacks({
    required this.ready,
    required this.degraded,
    required this.failed,
  });

  final bool Function({String? role}) ready;
  final bool Function({String? reason}) degraded;
  final bool Function({String? reason}) failed;
}

class RoomFailoverTransportHandle {
  const RoomFailoverTransportHandle(this.dispose);

  final FutureOr<void> Function() dispose;
}
