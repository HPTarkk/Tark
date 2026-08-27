import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_heartbeat_runtime.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/transport_route_proof_observation.dart';

void main() {
  TransportCapabilityControlCodec codec() => TransportCapabilityControlCodec(
    WakiPacketCodec('abcdef123456', SessionEpoch.startingAt(9)),
  );

  test('proof provider receives exact token and challenge epoch', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => null,
    );
    addTearDown(runtime.dispose);
    int? token;
    int? epoch;
    runtime.setRouteProofProvider(({
      required int token,
      required int challengeEpoch,
    }) async {
      token = token;
      epoch = challengeEpoch;
      return 'proof-$token-$challengeEpoch';
    });

    final bytes = await runtime.encodePong(
      token: 41,
      lastTxSeq: 1,
      lastRxSeq: 2,
      audioRxPackets: 3,
      challengeEpoch: 7,
    );
    final decoded = runtime.decodeControl(bytes, 'route-a');

    expect(token, 41);
    expect(epoch, 7);
    expect(decoded!.routeProof, 'proof-41-7');
  });

  test('decode alone grants no route proof observation', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => null,
    );
    addTearDown(runtime.dispose);
    final observations = <TransportRouteProofObservation>[];
    final subscription = runtime.routeProofObservations.listen(observations.add);
    addTearDown(subscription.cancel);

    final remote = codec().encodePong(
      token: 51,
      lastTxSeq: 1,
      lastRxSeq: 2,
      audioRxPackets: 3,
      routeProof: 'signed-proof',
    );
    final decoded = runtime.decodeControl(remote, '10.0.0.9')!;
    await Future<void>.delayed(Duration.zero);
    expect(observations, isEmpty);

    runtime.observeMatchedPong(
      decoded: decoded,
      peerKey: 'payload-sender',
      observedAt: DateTime.utc(2026, 8, 27, 19),
      challengeEpoch: 12,
    );
    await Future<void>.delayed(Duration.zero);

    expect(observations, hasLength(1));
    expect(observations.single.peerKey, '10.0.0.9');
    expect(observations.single.token, 51);
    expect(observations.single.challengeEpoch, 12);
    expect(observations.single.encodedProof, 'signed-proof');
  });

  test('provider failure and missing challenge epoch emit no proof', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => null,
    );
    addTearDown(runtime.dispose);
    runtime.setRouteProofProvider(({
      required int token,
      required int challengeEpoch,
    }) async => throw StateError('secure identity unavailable'));

    final bytes = await runtime.encodePong(
      token: 61,
      lastTxSeq: 1,
      lastRxSeq: 2,
      audioRxPackets: 3,
      challengeEpoch: 4,
    );
    expect(runtime.decodeControl(bytes, 'peer')!.routeProof, isNull);

    runtime.setRouteProofProvider(({
      required int token,
      required int challengeEpoch,
    }) async => 'proof');
    final noEpoch = await runtime.encodePong(
      token: 62,
      lastTxSeq: 1,
      lastRxSeq: 2,
      audioRxPackets: 3,
    );
    expect(runtime.decodeControl(noEpoch, 'peer')!.routeProof, isNull);
  });
}
