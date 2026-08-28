import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/service/room_capability_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_controller.dart';
import 'package:tark/feature/room/domain/service/room_failover_runtime.dart';
import 'package:tark/feature/room/domain/service/room_failover_transport_orchestrator.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/domain/service/room_session_runtime.dart';
import 'package:tark/feature/room/domain/service/room_verified_transport_capability_runtime.dart';
import 'package:tark/feature/room/domain/service/room_verified_transport_evidence_bridge.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const localMemberId = RoomMemberId('111111111111111111111111');
  const peerMemberId = RoomMemberId('222222222222222222222222');
  final now = DateTime.utc(2026, 8, 28, 5);

  Future<
    ({
      RoomVerifiedTransportCapabilityRuntime runtime,
      RoomMemberTransportKeyPair peer,
      RoomMemberTransportCertificate certificate,
    })
  >
  subject() async {
    final issuer = await crypto.generateKeyPair();
    final peer = await crypto.generateKeyPair();
    final certificate = await crypto.issueCertificate(
      roomId: roomId,
      memberId: peerMemberId,
      memberPublicKey: peer.publicKey,
      issuer: issuer,
    );
    final session = RoomSessionRuntime(
      initialState: RoomSession.open(
        roomId: roomId.value,
        sessionId: 'session-a',
        localMemberId: localMemberId.value,
        memberIds: [peerMemberId.value],
      ),
    );
    final failover = RoomFailoverRuntime(session: session);
    final orchestrator = RoomFailoverTransportOrchestrator(
      runtime: failover,
      startTransport: (_) async => RoomFailoverTransportHandle(() async {}),
    );
    return (
      runtime: RoomVerifiedTransportCapabilityRuntime(
        capability: RoomCapabilityFailoverRuntime(orchestrator: orchestrator),
        expectedIssuerPublicKey: issuer.publicKey,
      ),
      peer: peer,
      certificate: certificate,
    );
  }

  Future<String> proof({
    required RoomMemberTransportCertificate certificate,
    required RoomMemberTransportKeyPair peer,
    required int token,
    required int epoch,
  }) async => (await crypto.signProof(
    certificate: certificate,
    member: peer,
    token: token,
    sessionEpoch: epoch,
  )).encode();

  TransportCapabilityObservation peerCapability(String route) =>
      TransportCapabilityObservation(
        peerKey: route,
        capability: const TransportCapabilityAdvertisement(
          canHostHotspot: true,
          bluetoothSupported: true,
          backgroundReady: true,
          batteryPercent: 100,
          prefersHotspotHost: true,
        ),
        observedAt: now,
      );

  test(
    'capability is non-authoritative until matching signed proof binds route',
    () async {
      final value = await subject();
      final source = _EvidenceSource();
      final bridge = RoomVerifiedTransportEvidenceBridge(
        runtime: value.runtime,
        capabilitySource: source,
        proofExchange: source,
        localProofProvider: ({
          required int token,
          required int challengeEpoch,
        }) async => 'local-$token-$challengeEpoch',
      );
      value.runtime.observeLocal(
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 30,
        at: now,
      );

      source.capabilities.add(peerCapability('route-a'));
      expect(bridge.pendingCapabilityCount, 1);

      source.proofs.add(
        TransportRouteProofObservation(
          peerKey: 'route-a',
          token: 41,
          challengeEpoch: 7,
          encodedProof: await proof(
            certificate: value.certificate,
            peer: value.peer,
            token: 41,
            epoch: 7,
          ),
          observedAt: now,
        ),
      );
      await _flush();

      expect(bridge.pendingCapabilityCount, 0);
      final attempt = await value.runtime.beginFailover(
        sharedLanUsable: false,
        reason: RoomFailoverReason.hostLost,
        now: now,
      );
      expect(attempt!.decision.plan.hotspotHost, peerMemberId);

      await bridge.dispose();
      value.runtime.dispose();
      await source.close();
    },
  );

  test('forged proof never unlocks pending capability', () async {
    final value = await subject();
    final source = _EvidenceSource();
    final bridge = RoomVerifiedTransportEvidenceBridge(
      runtime: value.runtime,
      capabilitySource: source,
      proofExchange: source,
      localProofProvider: ({
        required int token,
        required int challengeEpoch,
      }) async => null,
    );
    value.runtime.observeLocal(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 30,
      at: now,
    );
    source.capabilities.add(peerCapability('route-a'));

    final valid = RoomMemberTransportProof.decode(
      await proof(
        certificate: value.certificate,
        peer: value.peer,
        token: 9,
        epoch: 3,
      ),
    );
    final signature = valid.memberSignature.toList()..[0] ^= 0xff;
    source.proofs.add(
      TransportRouteProofObservation(
        peerKey: 'route-a',
        token: 9,
        challengeEpoch: 3,
        encodedProof: RoomMemberTransportProof(
          certificate: valid.certificate,
          token: valid.token,
          sessionEpoch: valid.sessionEpoch,
          memberSignature: signature,
        ).encode(),
        observedAt: now,
      ),
    );
    await _flush();

    expect(bridge.pendingCapabilityCount, 1);
    final attempt = await value.runtime.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.hostLost,
      now: now,
    );
    expect(attempt!.decision.plan.hotspotHost, localMemberId);

    await bridge.dispose();
    value.runtime.dispose();
    await source.close();
  });

  test('proof for another carrier route cannot unlock capability', () async {
    final value = await subject();
    final source = _EvidenceSource();
    final bridge = RoomVerifiedTransportEvidenceBridge(
      runtime: value.runtime,
      capabilitySource: source,
      proofExchange: source,
      localProofProvider: ({
        required int token,
        required int challengeEpoch,
      }) async => null,
    );
    value.runtime.observeLocal(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 30,
      at: now,
    );
    source.capabilities.add(peerCapability('route-a'));
    source.proofs.add(
      TransportRouteProofObservation(
        peerKey: 'route-b',
        token: 17,
        challengeEpoch: 5,
        encodedProof: await proof(
          certificate: value.certificate,
          peer: value.peer,
          token: 17,
          epoch: 5,
        ),
        observedAt: now,
      ),
    );
    await _flush();

    expect(bridge.pendingCapabilityCount, 1);
    final attempt = await value.runtime.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.hostLost,
      now: now,
    );
    expect(attempt!.decision.plan.hotspotHost, localMemberId);

    await bridge.dispose();
    value.runtime.dispose();
    await source.close();
  });

  test('local proof provider is installed only for bridge lifetime', () async {
    final value = await subject();
    final source = _EvidenceSource();
    final bridge = RoomVerifiedTransportEvidenceBridge(
      runtime: value.runtime,
      capabilitySource: source,
      proofExchange: source,
      localProofProvider: ({
        required int token,
        required int challengeEpoch,
      }) async => '$token:$challengeEpoch',
    );

    expect(source.provider, isNotNull);
    expect(await source.provider!(token: 4, challengeEpoch: 6), '4:6');

    await bridge.dispose();
    expect(source.provider, isNull);
    value.runtime.dispose();
    await source.close();
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _EvidenceSource
    implements
        TransportCapabilityObservationSource,
        TransportRouteProofExchange {
  final capabilities =
      StreamController<TransportCapabilityObservation>.broadcast(sync: true);
  final proofs = StreamController<TransportRouteProofObservation>.broadcast(
    sync: true,
  );
  TransportRouteProofProvider? provider;

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      capabilities.stream;

  @override
  Stream<TransportRouteProofObservation> get routeProofObservations =>
      proofs.stream;

  @override
  void setRouteProofProvider(TransportRouteProofProvider? value) {
    provider = value;
  }

  Future<void> close() async {
    await capabilities.close();
    await proofs.close();
  }
}
