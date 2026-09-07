import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/logger.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/service/room_connection_readiness_gate.dart';
import 'package:tark/feature/room/domain/service/room_connection_trace.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';

void main() {
  const local = RoomMemberId('aaaaaaaaaaaaaaaaaaaaaaaa');
  const peer = RoomMemberId('bbbbbbbbbbbbbbbbbbbbbbbb');

  tearDown(() {
    Logger.sink = null;
  });

  test('correlation is stable without exposing the durable room id', () {
    const rawRoomId = '0123456789abcdef0123456789abcdef';
    final first = RoomConnectionTrace.correlationId(rawRoomId);
    final second = RoomConnectionTrace.correlationId(rawRoomId);

    expect(first, second);
    expect(first, matches(RegExp(r'^rc-[0-9a-f]{8}$')));
    expect(first, isNot(contains(rawRoomId)));
    expect(
      RoomConnectionTrace.correlationId('fedcba9876543210fedcba9876543210'),
      isNot(first),
    );
  });

  test(
    'readiness diagnostics carry one correlation through key stages',
    () async {
      final lines = <String>[];
      Logger.sink = lines.add;
      const roomId = '0123456789abcdef0123456789abcdef';
      final runtime = RoomSessionRuntime(
        initialState: RoomSession.open(
          roomId: roomId,
          sessionId: 'session-1',
          localMemberId: local.value,
          memberIds: [local.value, peer.value],
        ),
      );
      final proofs = StreamController<RoomPeerProofEvidence>.broadcast(
        sync: true,
      );
      final generation = await runtime.attach(kind: TransportKind.hotspot);
      const epoch = 3;

      final waiting =
          const RoomConnectionReadinessGate(
            timeout: Duration(milliseconds: 100),
          ).wait(
            runtime: runtime,
            peerProofs: proofs.stream,
            initialPeerProofs: const [],
            expectedPeers: const {peer},
            epoch: epoch,
            currentEpoch: () => epoch,
          );

      runtime.ready(generation: generation);
      proofs.add(
        RoomPeerProofEvidence(memberId: peer, attachmentGeneration: generation),
      );
      expect((await waiting).isReady, isTrue);

      final correlation = RoomConnectionTrace.correlationId(roomId);
      expect(
        lines.where((line) => line.contains('corr=$correlation')).length,
        greaterThanOrEqualTo(4),
      );
      expect(lines, contains(contains('stage=wait_started')));
      expect(lines, contains(contains('stage=transport_ready')));
      expect(lines, contains(contains('stage=peer_proof_observed')));
      expect(lines, contains(contains('stage=ready')));
      expect(lines.every((line) => !line.contains(roomId)), isTrue);

      await proofs.close();
      await runtime.leave();
    },
  );
}
