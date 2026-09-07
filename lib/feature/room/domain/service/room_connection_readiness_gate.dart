import 'dart:async';

import '../entity/room.dart';
import '../entity/room_session.dart';
import '../entity/transport_attachment.dart';
import 'room_session_runtime.dart';

/// A cryptographically verified peer observed on one concrete transport
/// attachment generation.
///
/// The generation is part of the evidence on purpose: a delayed proof from a
/// socket/network that has already been replaced must never make the new
/// attachment look ready.
final class RoomPeerProofEvidence {
  const RoomPeerProofEvidence({
    required this.memberId,
    required this.attachmentGeneration,
  });

  final RoomMemberId memberId;
  final int attachmentGeneration;
}

/// Safe, credential-free failure stages for pre-live diagnostics.
enum RoomConnectionReadinessFailureStage {
  transportBindTimeout,
  peerProofMissing,
  staleEpoch,
}

final class RoomConnectionReadinessResult {
  const RoomConnectionReadinessResult._({
    required this.transportReady,
    required this.peerProof,
    this.failure,
  });

  const RoomConnectionReadinessResult.ready({
    required Set<RoomMemberId> peerProof,
  }) : this._(transportReady: true, peerProof: peerProof);

  const RoomConnectionReadinessResult.failed({
    required bool transportReady,
    required Set<RoomMemberId> peerProof,
    required RoomConnectionReadinessFailureStage failure,
  }) : this._(
         transportReady: transportReady,
         peerProof: peerProof,
         failure: failure,
       );

  final bool transportReady;
  final Set<RoomMemberId> peerProof;
  final RoomConnectionReadinessFailureStage? failure;

  bool get isReady => transportReady && peerProof.isNotEmpty && failure == null;
}

/// Waits for both halves of the live Room boundary.
///
/// [RoomSessionPhase.live] means the selected transport has reached its
/// healthy/bound state. It is intentionally insufficient on its own. At least
/// one other active member must also present a signed Room route proof on the
/// *same attachment generation*. That proof is the application-level
/// hello/ack: it demonstrates bidirectional control traffic and durable Room
/// identity over the carrier that is actually bound.
///
/// [currentEpoch] fences the wait against cancel/restart races owned by the
/// Room connection coordinator without making this gate depend on transport
/// planning policy.
final class RoomConnectionReadinessGate {
  const RoomConnectionReadinessGate({
    this.timeout = const Duration(seconds: 12),
  });

  final Duration timeout;

  Future<RoomConnectionReadinessResult> wait({
    required RoomSessionRuntime runtime,
    required Stream<RoomPeerProofEvidence> peerProofs,
    required Iterable<RoomPeerProofEvidence> initialPeerProofs,
    required Set<RoomMemberId> expectedPeers,
    required int epoch,
    required int Function() currentEpoch,
  }) async {
    final completer = Completer<RoomConnectionReadinessResult>();
    final proofGenerationByMember = <RoomMemberId, int>{};
    StreamSubscription<RoomSession>? runtimeSubscription;
    StreamSubscription<RoomPeerProofEvidence>? proofSubscription;
    Timer? timer;

    bool transportReady = _isTransportReady(runtime.state);

    void remember(RoomPeerProofEvidence evidence) {
      if (expectedPeers.contains(evidence.memberId)) {
        proofGenerationByMember[evidence.memberId] =
            evidence.attachmentGeneration;
      }
    }

    for (final evidence in initialPeerProofs) {
      remember(evidence);
    }

    Set<RoomMemberId> currentProof() {
      final generation = runtime.attachmentGeneration;
      return Set.unmodifiable(
        proofGenerationByMember.entries
            .where((entry) => entry.value == generation)
            .map((entry) => entry.key)
            .toSet(),
      );
    }

    Future<void> finish(RoomConnectionReadinessResult result) async {
      if (completer.isCompleted) return;
      completer.complete(result);
      timer?.cancel();
      await runtimeSubscription?.cancel();
      await proofSubscription?.cancel();
    }

    void failStale() {
      unawaited(
        finish(
          RoomConnectionReadinessResult.failed(
            transportReady: transportReady,
            peerProof: currentProof(),
            failure: RoomConnectionReadinessFailureStage.staleEpoch,
          ),
        ),
      );
    }

    void settleIfReady() {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      final proof = currentProof();
      if (!transportReady || proof.isEmpty) return;
      unawaited(finish(RoomConnectionReadinessResult.ready(peerProof: proof)));
    }

    runtimeSubscription = runtime.changes.listen((state) {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      transportReady = _isTransportReady(state);
      settleIfReady();
    }, onError: (Object _) {});

    proofSubscription = peerProofs.listen((evidence) {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      remember(evidence);
      settleIfReady();
    }, onError: (Object _) {});

    timer = Timer(timeout, () {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      final proof = currentProof();
      unawaited(
        finish(
          RoomConnectionReadinessResult.failed(
            transportReady: transportReady,
            peerProof: proof,
            failure: transportReady
                ? RoomConnectionReadinessFailureStage.peerProofMissing
                : RoomConnectionReadinessFailureStage.transportBindTimeout,
          ),
        ),
      );
    });

    settleIfReady();
    return completer.future;
  }

  static bool _isTransportReady(RoomSession state) =>
      state.phase == RoomSessionPhase.live &&
      state.attachment.phase == TransportAttachmentPhase.attached;
}
