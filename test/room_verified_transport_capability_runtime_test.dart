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

void main() {
  final crypto = RoomMemberTransportIdentityCrypto();
  final roomId = RoomId('a' * 32);
  const localMemberId = RoomMemberId('111111111111111111111111');
  const peerMemberId = RoomMemberId('222222222222222222222222');
  final now = DateTime.utc(2026, 8, 27, 18);

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
        memberIds: const [peerMemberId.value],
      ),
    );
    final failover = RoomFailoverRuntime(session: session);
    final orchestrator = RoomFailoverTransportOrchestrator(
      runtime: failover,
      startTransport: (_) async => RoomFailoverTransportHandle(() async {}),
    );
    final capability = RoomCapabilityFailoverRuntime(orchestrator: orchestrator);
    return (
      runtime: RoomVerifiedTransportCapabilityRuntime(
        capability: capability,
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
  }) async {
    final signed = await crypto.signProof(
      certificate: certificate,
      member: peer,
      token: token,
      sessionEpoch: epoch,
    );
    return signed.encode();
  }

  test('unverified route cannot influence failover election', () async {
    final value = await subject();
    value.runtime.observeLocal(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 30,
      at: now,
    );

    expect(
      value.runtime.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 100,
        at: now,
        prefersHotspotHost: true,
      ),
      isFalse,
    );

    final attempt = await value.runtime.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.hostLost,
      now: now,
    );
    expect(attempt!.decision.plan.hotspotHost, localMemberId);
    value.runtime.dispose();
  });

  test('valid proof unlocks only its carrier route for election', () async {
    final value = await subject();
    expect(
      value.runtime.observeChallenge(
        peerKey: 'route-a',
        token: 41,
        sessionEpoch: 7,
        at: now,
      ),
      isTrue,
    );
    final encoded = await proof(
      certificate: value.certificate,
      peer: value.peer,
      token: 41,
      epoch: 7,
    );

    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-b',
        encodedProof: encoded,
        at: now,
      ),
      isFalse,
    );
    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: encoded,
        at: now,
      ),
      isTrue,
    );
    expect(
      value.runtime.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 90,
        at: now,
      ),
      isTrue,
    );
    value.runtime.dispose();
  });

  test('forged proof cannot unlock capability evidence', () async {
    final value = await subject();
    value.runtime.observeChallenge(
      peerKey: 'route-a',
      token: 9,
      sessionEpoch: 3,
      at: now,
    );
    final valid = await crypto.signProof(
      certificate: value.certificate,
      member: value.peer,
      token: 9,
      sessionEpoch: 3,
    );
    final tamperedSignature = valid.memberSignature.toList();
    tamperedSignature[0] ^= 0xff;
    final forged = RoomMemberTransportProof(
      certificate: valid.certificate,
      token: valid.token,
      sessionEpoch: valid.sessionEpoch,
      memberSignature: tamperedSignature,
    );

    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: forged.encode(),
        at: now,
      ),
      isFalse,
    );
    expect(
      value.runtime.observePeer(
        peerKey: 'route-a',
        canHostHotspot: true,
        bluetoothSupported: true,
        backgroundReady: true,
        batteryPercent: 100,
        at: now,
      ),
      isFalse,
    );
    value.runtime.dispose();
  });

  test('failover generation rejects delayed duplicate proof', () async {
    final value = await subject();
    value.runtime.observeLocal(
      canHostHotspot: true,
      bluetoothSupported: true,
      backgroundReady: true,
      batteryPercent: 30,
      at: now,
    );
    value.runtime.observeChallenge(
      peerKey: 'route-a',
      token: 17,
      sessionEpoch: 5,
      at: now,
    );
    final encoded = await proof(
      certificate: value.certificate,
      peer: value.peer,
      token: 17,
      epoch: 5,
    );
    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: encoded,
        at: now,
      ),
      isTrue,
    );

    final attempt = await value.runtime.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.hostLost,
      now: now,
    );
    expect(attempt!.attachmentGeneration, 1);
    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: encoded,
        at: now.add(const Duration(seconds: 1)),
      ),
      isFalse,
    );
    value.runtime.dispose();
  });

  test('removed member proof remains fail closed', () async {
    final value = await subject();
    value.runtime.observeChallenge(
      peerKey: 'route-a',
      token: 23,
      sessionEpoch: 8,
      at: now,
    );
    final encoded = await proof(
      certificate: value.certificate,
      peer: value.peer,
      token: 23,
      epoch: 8,
    );
    value.runtime.replaceMembers(const [localMemberId]);

    expect(
      await value.runtime.verifyAndBind(
        peerKey: 'route-a',
        encodedProof: encoded,
        at: now,
      ),
      isFalse,
    );
    value.runtime.dispose();
  });
}
