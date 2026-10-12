import 'dart:async';

import '../entity/room.dart';
import '../entity/room_session.dart';
import '../entity/transport_attachment.dart';
import 'room_connection_trace.dart';
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
    this.transportSenderId,
    this.carrierRoute,
  });

  final RoomMemberId memberId;
  final int attachmentGeneration;

  /// Ephemeral sender id observed on the exact proof-bearing control exchange.
  ///
  /// This is never membership authority. It is retained only so presentation
  /// can join volatile transport presence (such as `isTalking`) to the member
  /// whose route has already passed the signed Room proof above. Null means the
  /// transport cannot safely provide that projection and therefore fails closed
  /// for speaking UI without affecting readiness.
  final String? transportSenderId;

  /// The opaque carrier route this proof arrived on (on Wi-Fi, the source
  /// address). Never identity, like [transportSenderId]: it exists so a move
  /// between networks can be confirmed by the member *proving* itself on the
  /// new one, rather than by the move merely having been asked for.
  final String? carrierRoute;
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
    this.activityGrace = const Duration(seconds: 10),
    this.activityCeiling = const Duration(seconds: 30),
  });

  /// How long the wait lasts when nothing at all is heard from the others.
  final Duration timeout;

  /// How long after the latest sign of another phone the wait keeps going.
  ///
  /// [timeout] answers "is anybody there?", which is quick to answer when
  /// nobody is. Once somebody demonstrably is — their traffic is arriving on
  /// this link — the question becomes "has the signed hello finished?", and
  /// that takes as long as both ends' sockets take to settle. A fixed four
  /// seconds gave up 0.4 s after first hearing the other phone, while that
  /// phone finished the same exchange and went live three seconds later: two
  /// phones in one Room, one in the call and one back at a scanner
  /// (2026-10-12 logs). Traffic now buys the exchange time to finish.
  final Duration activityGrace;

  /// The most that heard traffic can add on top of [timeout]. A peer that is
  /// audible but never completes the proof (a different build, a broken
  /// identity) must still end in a failure the user can act on.
  final Duration activityCeiling;

  Future<RoomConnectionReadinessResult> wait({
    required RoomSessionRuntime runtime,
    required Stream<RoomPeerProofEvidence> peerProofs,
    required Iterable<RoomPeerProofEvidence> initialPeerProofs,
    required Set<RoomMemberId> expectedPeers,
    required int epoch,
    required int Function() currentEpoch,
    Stream<void>? peerActivity,
    Future<void>? abandoned,
  }) async {
    final completer = Completer<RoomConnectionReadinessResult>();
    final proofGenerationByMember = <RoomMemberId, int>{};
    StreamSubscription<RoomSession>? runtimeSubscription;
    StreamSubscription<RoomPeerProofEvidence>? proofSubscription;
    StreamSubscription<void>? activitySubscription;
    Timer? timer;
    final startedAt = DateTime.now();
    var deadline = startedAt.add(timeout);
    final ceiling = deadline.add(activityCeiling);
    var activityTraced = false;

    final roomId = runtime.state.roomId;
    bool transportReady = _isTransportReady(runtime.state);
    RoomConnectionTrace.stage(
      roomId: roomId,
      attempt: epoch,
      stage: 'wait_started',
      attachmentGeneration: runtime.attachmentGeneration,
    );
    if (transportReady) {
      RoomConnectionTrace.stage(
        roomId: roomId,
        attempt: epoch,
        stage: 'transport_ready',
        attachmentGeneration: runtime.attachmentGeneration,
      );
    }

    void remember(RoomPeerProofEvidence evidence) {
      if (!expectedPeers.contains(evidence.memberId)) return;
      proofGenerationByMember[evidence.memberId] =
          evidence.attachmentGeneration;
      if (evidence.attachmentGeneration == runtime.attachmentGeneration) {
        RoomConnectionTrace.stage(
          roomId: roomId,
          attempt: epoch,
          stage: 'peer_proof_observed',
          attachmentGeneration: evidence.attachmentGeneration,
        );
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
      await activitySubscription?.cancel();
    }

    void failStale() {
      RoomConnectionTrace.stage(
        roomId: roomId,
        attempt: epoch,
        stage: 'stale_epoch',
        attachmentGeneration: runtime.attachmentGeneration,
      );
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
      RoomConnectionTrace.stage(
        roomId: roomId,
        attempt: epoch,
        stage: 'ready',
        attachmentGeneration: runtime.attachmentGeneration,
      );
      unawaited(finish(RoomConnectionReadinessResult.ready(peerProof: proof)));
    }

    runtimeSubscription = runtime.changes.listen((state) {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      final wasReady = transportReady;
      transportReady = _isTransportReady(state);
      if (!wasReady && transportReady) {
        RoomConnectionTrace.stage(
          roomId: roomId,
          attempt: epoch,
          stage: 'transport_ready',
          attachmentGeneration: runtime.attachmentGeneration,
        );
      }
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

    void onDeadline() {
      if (completer.isCompleted) return;
      if (currentEpoch() != epoch) {
        failStale();
        return;
      }
      final proof = currentProof();
      final failure = transportReady
          ? RoomConnectionReadinessFailureStage.peerProofMissing
          : RoomConnectionReadinessFailureStage.transportBindTimeout;
      RoomConnectionTrace.stage(
        roomId: roomId,
        attempt: epoch,
        stage: failure == RoomConnectionReadinessFailureStage.peerProofMissing
            ? 'peer_proof_missing'
            : 'transport_bind_timeout',
        attachmentGeneration: runtime.attachmentGeneration,
      );
      unawaited(
        finish(
          RoomConnectionReadinessResult.failed(
            transportReady: transportReady,
            peerProof: proof,
            failure: failure,
          ),
        ),
      );
    }

    timer = Timer(timeout, onDeadline);

    activitySubscription = peerActivity?.listen((_) {
      if (completer.isCompleted) return;
      final now = DateTime.now();
      var extended = now.add(activityGrace);
      if (extended.isAfter(ceiling)) extended = ceiling;
      if (!extended.isAfter(deadline)) return;
      deadline = extended;
      if (!activityTraced) {
        activityTraced = true;
        RoomConnectionTrace.stage(
          roomId: roomId,
          attempt: epoch,
          stage: 'peer_heard',
          attachmentGeneration: runtime.attachmentGeneration,
        );
      }
      timer?.cancel();
      timer = Timer(deadline.difference(now), onDeadline);
    }, onError: (Object _) {});

    // An attempt the caller has walked away from (a scan arrived, the user
    // switched sides) ends now rather than whenever its next event or the
    // deadline happens to land — which, for a passive listener, could be
    // minutes of a subscription nobody is reading.
    unawaited(
      abandoned?.then<void>((_) {
        if (!completer.isCompleted) failStale();
      }),
    );

    settleIfReady();
    return completer.future;
  }

  static bool _isTransportReady(RoomSession state) =>
      state.phase == RoomSessionPhase.live &&
      state.attachment.phase == TransportAttachmentPhase.attached;
}
