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
            expectedPeers: const {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
          );

      subject.ready(generation: generation);
      proofs.add(
        RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
      );

      final result = await waiting;
      expect(result.isReady, isTrue);
      expect(result.peerProof, const {peer});
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
          expectedPeers: const {peer},
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
            expectedPeers: const {peer},
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
          expectedPeers: const {peer},
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
          expectedPeers: const {peer},
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
}
