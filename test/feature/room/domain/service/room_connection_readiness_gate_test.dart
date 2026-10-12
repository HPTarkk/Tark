import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_connection_readiness_gate.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';

void main() {
  const local = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa');
  const peer = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');

  RoomSessionRuntime runtime() => RoomSessionRuntime(
    initialState: RoomSession.open(
      roomId: 'room-1',
      sessionId: 'session-1',
      localMemberId: local.value,
      memberIds: [local.value, peer.value],
    ),
  );

  test(
    'healthy attachment plus current signed peer proof becomes ready',
    () async {
      final subject = runtime();
      final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
        sync: true,
      );
      final generation = await subject.attach(kind: TransportKind.hotspot);
      const epoch = 1;
      final waiting =
          const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 100),
          ).wait(
            runtime: subject,
            peerProofs: proofs.stream,
            initialPeerProofs: const [],
            expectedPeers: {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
          );

      subject.ready(generation: generation);
      proofs.add(
        RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
      );

      final result = await waiting;
      expect(result.isReady, isTrue);
      expect(result.peerProof, {peer});
      await proofs.close();
      await subject.leave();
    },
  );

  test('bind timeout cannot become live from peer proof alone', () async {
    final subject = runtime();
    final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
      sync: true,
    );
    final generation = await subject.attach(kind: TransportKind.hotspot);
    const epoch = 1;
    final waiting =
        const RoomConnectionReadinessGate(
          timeout: Duration(milliseconds: 20),
        ).wait(
          runtime: subject,
          peerProofs: proofs.stream,
          initialPeerProofs: const [],
          expectedPeers: {peer},
          epoch: epoch,
          currentEpoch: () => epoch,
        );

    proofs.add(
      RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
    );

    final result = await waiting;
    expect(result.isReady, isFalse);
    expect(result.transportReady, isFalse);
    expect(
      result.failure,
      RoomConnectionReadinessFailureStage.transportBindTimeout,
    );
    await proofs.close();
    await subject.leave();
  });

  test(
    'healthy transport without authenticated peer proof stays closed',
    () async {
      final subject = runtime();
      final generation = await subject.attach(kind: TransportKind.hotspot);
      subject.ready(generation: generation);
      const epoch = 1;

      final result =
          await const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 20),
          ).wait(
            runtime: subject,
            peerProofs: const Stream<RoomPeerProofEvidence>.empty(),
            initialPeerProofs: const [],
            expectedPeers: {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
          );

      expect(result.isReady, isFalse);
      expect(result.transportReady, isTrue);
      expect(
        result.failure,
        RoomConnectionReadinessFailureStage.peerProofMissing,
      );
      await subject.leave();
    },
  );

  test('late callback from a cancelled epoch is rejected', () async {
    final subject = runtime();
    final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
      sync: true,
    );
    final generation = await subject.attach(kind: TransportKind.hotspot);
    var currentEpoch = 1;
    final waiting =
        const RoomConnectionReadinessGate(
          timeout: Duration(milliseconds: 100),
        ).wait(
          runtime: subject,
          peerProofs: proofs.stream,
          initialPeerProofs: const [],
          expectedPeers: {peer},
          epoch: 1,
          currentEpoch: () => currentEpoch,
        );

    currentEpoch = 2;
    subject.ready(generation: generation);
    proofs.add(
      RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
    );

    final result = await waiting;
    expect(result.isReady, isFalse);
    expect(result.failure, RoomConnectionReadinessFailureStage.staleEpoch);
    await proofs.close();
    await subject.leave();
  });

  test('proof from replaced attachment cannot satisfy rebind', () async {
    final subject = runtime();
    final oldGeneration = await subject.attach(kind: TransportKind.hotspot);
    subject.ready(generation: oldGeneration);
    final newGeneration = await subject.replaceTransport(
      kind: TransportKind.hotspot,
      reason: 'test_rebind',
    );
    subject.ready(generation: newGeneration);
    const epoch = 1;

    final result =
        await const RoomConnectionReadinessGate(
          timeout: Duration(milliseconds: 20),
        ).wait(
          runtime: subject,
          peerProofs: const Stream<RoomPeerProofEvidence>.empty(),
          initialPeerProofs: [
            RoomPeerProofEvidence(
              memberId: peer,
              attachmentGeneration: oldGeneration,
            ),
          ],
          expectedPeers: {peer},
          epoch: epoch,
          currentEpoch: () => epoch,
        );

    expect(result.isReady, isFalse);
    expect(result.transportReady, isTrue);
    expect(result.peerProof, isEmpty);
    expect(
      result.failure,
      RoomConnectionReadinessFailureStage.peerProofMissing,
    );
    await subject.leave();
  });

  group('heard traffic', () {
    // 2026-10-12: the existing-link check gave up 0.4 s after first hearing
    // the other phone, which then went live on the same exchange three
    // seconds later. Traffic on the link must buy the hello time to finish.
    test('extends the wait so a slow signed hello still lands', () async {
      final subject = runtime();
      final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
        sync: true,
      );
      final heard = StreamController<void>.broadcast(sync: true);
      final generation = await subject.attach(kind: TransportKind.hotspot);
      subject.ready(generation: generation);
      const epoch = 1;
      final waiting =
          const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 60),
            activityGrace: Duration(milliseconds: 200),
            activityCeiling: Duration(milliseconds: 400),
          ).wait(
            runtime: subject,
            peerProofs: proofs.stream,
            initialPeerProofs: const [],
            expectedPeers: {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
            peerActivity: heard.stream,
          );

      await Future<void>.delayed(const Duration(milliseconds: 40));
      heard.add(null);
      // Past the bare timeout, inside the grace the traffic bought.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      proofs.add(
        RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
      );

      final result = await waiting;
      expect(result.isReady, isTrue);
      await proofs.close();
      await heard.close();
      await subject.leave();
    });

    test('cannot keep an unanswered wait open past the ceiling', () async {
      final subject = runtime();
      final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
        sync: true,
      );
      final heard = StreamController<void>.broadcast(sync: true);
      final generation = await subject.attach(kind: TransportKind.hotspot);
      subject.ready(generation: generation);
      const epoch = 1;
      final started = DateTime.now();
      final ticker = Timer.periodic(
        const Duration(milliseconds: 20),
        (_) => heard.add(null),
      );
      final result =
          await const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 50),
            activityGrace: Duration(milliseconds: 100),
            activityCeiling: Duration(milliseconds: 150),
          ).wait(
            runtime: subject,
            peerProofs: proofs.stream,
            initialPeerProofs: const [],
            expectedPeers: {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
            peerActivity: heard.stream,
          );
      ticker.cancel();

      expect(result.isReady, isFalse);
      expect(
        result.failure,
        RoomConnectionReadinessFailureStage.peerProofMissing,
      );
      final took = DateTime.now().difference(started);
      expect(took, greaterThanOrEqualTo(const Duration(milliseconds: 190)));
      expect(took, lessThan(const Duration(seconds: 2)));
      await proofs.close();
      await heard.close();
      await subject.leave();
    });

    test('silence still fails at the bare timeout', () async {
      final subject = runtime();
      final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
        sync: true,
      );
      final heard = StreamController<void>.broadcast(sync: true);
      final generation = await subject.attach(kind: TransportKind.hotspot);
      subject.ready(generation: generation);
      const epoch = 1;
      final started = DateTime.now();
      final result =
          await const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 50),
            activityGrace: Duration(seconds: 5),
            activityCeiling: Duration(seconds: 5),
          ).wait(
            runtime: subject,
            peerProofs: proofs.stream,
            initialPeerProofs: const [],
            expectedPeers: {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
            peerActivity: heard.stream,
          );

      expect(result.isReady, isFalse);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
      );
      await proofs.close();
      await heard.close();
      await subject.leave();
    });
  });

  test('an abandoned wait ends at once as stale', () async {
    final subject = runtime();
    final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
      sync: true,
    );
    final abandon = Completer<void>();
    await subject.attach(kind: TransportKind.hotspot);
    const epoch = 1;
    final started = DateTime.now();
    final waiting =
        const RoomConnectionReadinessGate(timeout: Duration(minutes: 3)).wait(
          runtime: subject,
          peerProofs: proofs.stream,
          initialPeerProofs: const [],
          expectedPeers: {peer},
          epoch: epoch,
          currentEpoch: () => epoch,
          abandoned: abandon.future,
        );
    abandon.complete();

    final result = await waiting;
    expect(result.failure, RoomConnectionReadinessFailureStage.staleEpoch);
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 2)),
    );
    await proofs.close();
    await subject.leave();
  });
}
