import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_heartbeat_runtime.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_advertisement.dart';
import 'package:tark/feature/transfer/domain/entity/transport_capability_observation.dart';

void main() {
  const capability = TransportCapabilityAdvertisement(
    canHostHotspot: true,
    bluetoothSupported: true,
    backgroundReady: true,
    batteryPercent: 82,
  );

  TransportCapabilityControlCodec codec() => TransportCapabilityControlCodec(
    WakiPacketCodec('abcdef123456', SessionEpoch.startingAt(9)),
  );

  test('truthful local capability is appended on the existing heartbeat', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => capability,
    );
    addTearDown(runtime.dispose);

    final bytes = await runtime.encodePing(
      token: 1,
      lastTxSeq: 2,
      lastRxSeq: 3,
      audioRxPackets: 4,
    );
    final decoded = runtime.decodeControl(bytes, 'peer');

    expect(decoded, isNotNull);
    expect(decoded!.packet.token, 1);
    expect(decoded.capability, capability);
  });

  test('capability read failure preserves a valid legacy heartbeat', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => throw StateError('platform unavailable'),
    );
    addTearDown(runtime.dispose);

    final bytes = await runtime.encodePong(
      token: 5,
      lastTxSeq: 6,
      lastRxSeq: 7,
      audioRxPackets: 8,
    );
    final decoded = runtime.decodeControl(bytes, 'peer');

    expect(decoded, isNotNull);
    expect(decoded!.packet.token, 5);
    expect(decoded.capability, isNull);
  });

  test('decoded capability is not emitted until matched pong is admitted', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => null,
    );
    addTearDown(runtime.dispose);
    final observations = <TransportCapabilityObservation>[];
    final subscription = runtime.transportCapabilityObservations.listen(
      observations.add,
    );
    addTearDown(subscription.cancel);

    final remote = TransportCapabilityControlCodec(
      WakiPacketCodec('fedcba654321', SessionEpoch.startingAt(9)),
    ).encodePong(
      token: 11,
      lastTxSeq: 12,
      lastRxSeq: 13,
      audioRxPackets: 14,
      capability: capability,
    );
    final decoded = runtime.decodeControl(remote, '10.0.0.8')!;

    await Future<void>.delayed(Duration.zero);
    expect(observations, isEmpty);

    runtime.observeMatchedPong(
      decoded: decoded,
      peerKey: '10.0.0.8',
      observedAt: DateTime.utc(2026, 8, 27, 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(observations, hasLength(1));
    final observation = observations.single;
    expect(observation.peerKey, '10.0.0.8');
    expect(observation.capability, capability);
    expect(observation.observedAt, DateTime.utc(2026, 8, 27, 1));
  });

  test('missing capability and empty peer key fail closed', () async {
    final runtime = TransportCapabilityHeartbeatRuntime(
      codec: codec(),
      readLocalCapability: () async => null,
    );
    addTearDown(runtime.dispose);
    final observations = <TransportCapabilityObservation>[];
    final subscription = runtime.transportCapabilityObservations.listen(
      observations.add,
    );
    addTearDown(subscription.cancel);

    final noCapability = Uint8List.fromList(
      runtime.codec.base.encodePong(
        token: 21,
        lastTxSeq: 22,
        lastRxSeq: 23,
        audioRxPackets: 24,
      ),
    );
    final decodedNoCapability = runtime.decodeControl(noCapability, 'peer')!;
    runtime.observeMatchedPong(
      decoded: decodedNoCapability,
      peerKey: 'peer',
      observedAt: DateTime.utc(2026),
    );

    final withCapability = TransportCapabilityControlCodec(
      WakiPacketCodec('fedcba654321', SessionEpoch.startingAt(9)),
    ).encodePong(
      token: 25,
      lastTxSeq: 26,
      lastRxSeq: 27,
      audioRxPackets: 28,
      capability: capability,
    );
    runtime.observeMatchedPong(
      decoded: runtime.decodeControl(withCapability, 'peer')!,
      peerKey: '',
      observedAt: DateTime.utc(2026),
    );

    await Future<void>.delayed(Duration.zero);
    expect(observations, isEmpty);
  });
}
