import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/identity/session_epoch.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_session.dart';
import 'package:tark/feature/room/domain/entity/transport_attachment.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_connection_readiness_gate.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/domain/service/selected_room_live_session_binding.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_control_codec.dart';
import 'package:tark/feature/transfer/data/codec/transport_capability_heartbeat_runtime.dart';
import 'package:tark/feature/transfer/data/codec/waki_packet_codec.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const identityChannel = MethodChannel('tark/room_identity_secure_storage');
  final roomId = RoomId('a' * 32);
  final memberId = RoomMemberId('b' * 24);
  final now = DateTime.utc(2026, 8, 26, 10);

  // Only the Android encrypted-file boundary is replaced. The production
  // platform store still serializes and restores the signed key material.
  setUp(() {
    final storage = <String, Object?>{};
    messenger.setMockMethodCallHandler(identityChannel, (call) async {
      final args = call.arguments as Map;
      final key = '${args['roomId']}:${args['memberId']}';
      switch (call.method) {
        case 'write':
          storage[key] = args['material'];
          return null;
        case 'read':
          return storage[key];
        case 'delete':
          storage.remove(key);
          return null;
        default:
          throw MissingPluginException();
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(identityChannel, null));

  SavedRoom savedRoom() => SavedRoom(
    room: Room(
      id: roomId,
      name: 'Riders',
      createdAt: now,
      updatedAt: now,
      members: [RoomMember(id: memberId, displayName: 'Me', joinedAt: now)],
    ),
    membership: RoomMembership(localMemberId: memberId, canManageInvites: true),
  );

  test('selected durable room follows live transport health', () async {
    final rooms = _RoomRepository(selected: roomId, saved: savedRoom());
    final transfer = _TransferRepository(role: SessionRole.host);
    final binding = SelectedRoomLiveSessionBinding(
      rooms: rooms,
      transfer: transfer,
      modeStore: _ModeStore(TransferMode.hotspot),
    );

    final runtime = await binding.open(sessionId: 'live-1');

    expect(runtime, isNotNull);
    expect(runtime!.state.roomId, roomId.value);
    expect(runtime.state.localMemberId, memberId.value);
    expect(runtime.state.attachment.kind, TransportKind.hotspot);
    expect(runtime.state.attachment.role, SessionRole.host.name);
    expect(runtime.state.attachment.phase, TransportAttachmentPhase.attaching);
    expect(transfer.connectCalls, 1);

    transfer.health.add(const ConnectionHealth.healthy());
    expect(runtime.state.phase, RoomSessionPhase.live);

    transfer.health.add(const ConnectionHealth.reconnecting());
    expect(runtime.state.phase, RoomSessionPhase.recoveringTransport);
    expect(runtime.state.roomId, roomId.value);
    expect(runtime.state.localMemberId, memberId.value);

    await binding.close();
    expect(runtime.hasLeft, isTrue);
    expect(transfer.health.hasListener, isFalse);
    await transfer.health.close();
  });

  test(
    'adopts a healthy transport that bound before Room subscribed',
    () async {
      final rooms = _RoomRepository(selected: roomId, saved: savedRoom());
      final transfer = _TransferRepository(
        role: SessionRole.joiner,
        currentHealth: const ConnectionHealth.healthy(),
      );
      final binding = SelectedRoomLiveSessionBinding(
        rooms: rooms,
        transfer: transfer,
        modeStore: _ModeStore(TransferMode.hotspot),
      );

      final runtime = await binding.open(sessionId: 'already-bound');

      // This is the physical-device race: Wi-Fi's UDP bind became healthy
      // while the hotspot consent/join flow was completing, before Room began
      // listening to the broadcast health stream.
      expect(runtime, isNotNull);
      expect(runtime!.state.phase, RoomSessionPhase.live);
      expect(runtime.state.attachment.phase, TransportAttachmentPhase.attached);

      await binding.close();
      await transfer.health.close();
    },
  );

  test(
    'associated host and joiner open only after signed peer exchange',
    () async {
      final peers = await _associatedPeers(roomId: roomId, now: now);
      addTearDown(peers.close);
      const gate = RoomConnectionReadinessGate(timeout: Duration(seconds: 2));
      final hostReady = peers.wait(gate, host: true);
      final joinerReady = peers.wait(gate, host: false);

      // OS association/socket health is already green. It cannot manufacture
      // the application hello/ack required to open either phone's call screen.
      expect(peers.host.runtime!.state.phase, RoomSessionPhase.live);
      expect(peers.joiner.runtime!.state.phase, RoomSessionPhase.live);
      expect(peers.host.verifiedPeerProofSnapshot, isEmpty);
      expect(peers.joiner.verifiedPeerProofSnapshot, isEmpty);

      // Both responders use the providers installed by the real Room binding.
      // Production Ping/Pong codecs carry their certificates and signatures.
      await peers.hostTransfer.challenge(peers.joinerTransfer);
      await peers.joinerTransfer.challenge(peers.hostTransfer);

      expect((await hostReady).isReady, isTrue);
      expect((await joinerReady).isReady, isTrue);
      expect(
        peers.host.verifiedPeerProofSnapshot.single.memberId,
        peers.joinerId,
      );
      expect(
        peers.joiner.verifiedPeerProofSnapshot.single.memberId,
        peers.hostId,
      );
    },
  );

  test(
    'association and a forged peer proof cannot open Room readiness',
    () async {
      final peers = await _associatedPeers(roomId: roomId, now: now);
      addTearDown(peers.close);
      const gate = RoomConnectionReadinessGate(
        timeout: Duration(milliseconds: 100),
      );

      final withoutProof = await peers.wait(gate, host: true);
      expect(withoutProof.transportReady, isTrue);
      expect(withoutProof.isReady, isFalse);
      expect(
        withoutProof.failure,
        RoomConnectionReadinessFailureStage.peerProofMissing,
      );

      final withForgery = peers.wait(gate, host: true);
      await peers.hostTransfer.challenge(peers.joinerTransfer, forge: true);
      final rejected = await withForgery;
      expect(rejected.transportReady, isTrue);
      expect(rejected.isReady, isFalse);
      expect(
        rejected.failure,
        RoomConnectionReadinessFailureStage.peerProofMissing,
      );
      expect(peers.host.verifiedPeerProofSnapshot, isEmpty);
    },
  );

  test(
    'live failover reuses health stream and refreshes local evidence on down',
    () async {
      final transfer = _TransferRepository(role: SessionRole.host);
      var capabilityReads = 0;
      final binding = SelectedRoomLiveSessionBinding(
        rooms: _RoomRepository(selected: roomId, saved: savedRoom()),
        transfer: transfer,
        modeStore: _ModeStore(TransferMode.hotspot),
        hotspotHost: _HotspotHost(),
        hotspotLinkKeeper: _HotspotLinkKeeper(),
        identityStore: _IdentityStore(),
        localCapabilityReader: () async {
          capabilityReads += 1;
          return null;
        },
      );

      final runtime = await binding.open(sessionId: 'live-failover');

      expect(runtime, isNotNull);
      expect(transfer.connectCalls, 1);
      expect(capabilityReads, 1);

      transfer.health.add(const ConnectionHealth.down());
      await _flush();

      expect(capabilityReads, 2);
      expect(transfer.connectCalls, 1);
      expect(runtime!.state.roomId, roomId.value);
      expect(runtime.state.localMemberId, memberId.value);

      await binding.close();
      final readsAfterClose = capabilityReads;
      transfer.health.add(const ConnectionHealth.down());
      await _flush();

      expect(capabilityReads, readsAfterClose);
      expect(transfer.health.hasListener, isFalse);
      await transfer.health.close();
    },
  );

  test(
    'no selected room preserves legacy entry without touching transport',
    () async {
      final transfer = _TransferRepository();
      final binding = SelectedRoomLiveSessionBinding(
        rooms: _RoomRepository(),
        transfer: transfer,
        modeStore: _ModeStore(TransferMode.wifi),
      );

      expect(await binding.open(sessionId: 'live-2'), isNull);
      expect(transfer.connectCalls, 0);
      await transfer.health.close();
    },
  );

  test('close cancels a stale async open before it can own health', () async {
    final selected = Completer<RoomId?>();
    final transfer = _TransferRepository();
    final binding = SelectedRoomLiveSessionBinding(
      rooms: _RoomRepository(
        selectedFuture: selected.future,
        saved: savedRoom(),
      ),
      transfer: transfer,
      modeStore: _ModeStore(TransferMode.wifi),
    );

    final opening = binding.open(sessionId: 'live-stale');
    await Future<void>.delayed(Duration.zero);
    await binding.close();
    selected.complete(roomId);

    expect(await opening, isNull);
    expect(binding.runtime, isNull);
    expect(transfer.connectCalls, 0);
    expect(transfer.health.hasListener, isFalse);
    await transfer.health.close();
  });

  test('transport mode maps without changing room identity semantics', () {
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.wifi),
      TransportKind.wifi,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.hotspot),
      TransportKind.hotspot,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.bluetooth),
      TransportKind.bluetooth,
    );
    expect(
      SelectedRoomLiveSessionBinding.transportKindFor(TransferMode.guest),
      TransportKind.webrtc,
    );
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<_AssociatedPeers> _associatedPeers({
  required RoomId roomId,
  required DateTime now,
}) async {
  const hostId = RoomMemberId('111111111111111111111111');
  const joinerId = RoomMemberId('222222222222222222222222');
  final room = Room(
    id: roomId,
    name: 'Riders',
    createdAt: now,
    updatedAt: now,
    members: [
      RoomMember(id: hostId, displayName: 'Host', joinedAt: now),
      RoomMember(id: joinerId, displayName: 'Joiner', joinedAt: now),
    ],
  );
  final hostRoom = SavedRoom(
    room: room,
    membership: const RoomMembership(
      localMemberId: hostId,
      canManageInvites: true,
    ),
  );
  final joinerRoom = SavedRoom(
    room: room,
    membership: const RoomMembership(
      localMemberId: joinerId,
      canManageInvites: false,
    ),
  );
  final store = PlatformRoomTransportIdentitySecureStore();
  final identity = RoomTransportIdentityLifecycle(store: store);
  await identity.ensureLocalIdentity(hostRoom);
  final joinerKey = await identity.createPendingMemberKeyPair();
  final certificate = await identity.issueMemberCertificate(
    issuerRoom: hostRoom,
    memberId: joinerId,
    memberPublicKey: joinerKey.publicKey,
  );
  await identity.persistJoinedIdentity(
    saved: joinerRoom,
    memberKeyPair: joinerKey,
    certificate: certificate,
  );

  final hostTransfer = _ProofTransfer(SessionRole.host, '192.168.43.1', 7);
  final joinerTransfer = _ProofTransfer(SessionRole.joiner, '192.168.43.2', 11);
  SelectedRoomLiveSessionBinding binding(
    SavedRoom saved,
    _ProofTransfer transfer,
  ) => SelectedRoomLiveSessionBinding(
    rooms: _RoomRepository(selected: roomId, saved: saved),
    transfer: transfer,
    modeStore: _ModeStore(TransferMode.hotspot),
    hotspotHost: _HotspotHost(),
    hotspotLinkKeeper: _HotspotLinkKeeper(),
    identityStore: store,
    localCapabilityReader: () async => null,
  );

  final host = binding(hostRoom, hostTransfer);
  final joiner = binding(joinerRoom, joinerTransfer);
  await host.open(sessionId: 'host-after-association');
  await joiner.open(sessionId: 'joiner-after-association');
  return _AssociatedPeers(host, joiner, hostTransfer, joinerTransfer);
}

class _AssociatedPeers {
  _AssociatedPeers(
    this.host,
    this.joiner,
    this.hostTransfer,
    this.joinerTransfer,
  );

  final SelectedRoomLiveSessionBinding host;
  final SelectedRoomLiveSessionBinding joiner;
  final _ProofTransfer hostTransfer;
  final _ProofTransfer joinerTransfer;
  RoomMemberId get hostId => RoomMemberId(host.runtime!.state.localMemberId);
  RoomMemberId get joinerId =>
      RoomMemberId(joiner.runtime!.state.localMemberId);

  Future<RoomConnectionReadinessResult> wait(
    RoomConnectionReadinessGate gate, {
    required bool host,
  }) {
    final binding = host ? this.host : joiner;
    return gate.wait(
      runtime: binding.runtime!,
      peerProofs: binding.verifiedPeerProofs,
      initialPeerProofs: binding.verifiedPeerProofSnapshot,
      expectedPeers: {host ? joinerId : hostId},
      epoch: 1,
      currentEpoch: () => 1,
    );
  }

  Future<void> close() async {
    await host.close();
    await joiner.close();
    await hostTransfer.heartbeat.dispose();
    await joinerTransfer.heartbeat.dispose();
    await hostTransfer.health.close();
    await joinerTransfer.health.close();
  }
}

/// The associated network is the only fake: deliver wire bytes directly instead
/// of through Android UDP. Encoding, signing, storage, proof verification and
/// the Room readiness gate all use the production implementations.
class _ProofTransfer extends _TransferRepository
    implements
        TransportRouteProofExchange,
        TransportCapabilityObservationSource {
  _ProofTransfer(SessionRole role, this.address, int epoch)
    : epoch = SessionEpoch.startingAt(epoch),
      super(role: role, currentHealth: const ConnectionHealth.healthy()) {
    heartbeat = TransportCapabilityHeartbeatRuntime(
      codec: TransportCapabilityControlCodec(
        WakiPacketCodec(address, this.epoch),
      ),
      readLocalCapability: () async => null,
    );
  }

  final String address;
  final SessionEpoch epoch;
  late final TransportCapabilityHeartbeatRuntime heartbeat;
  int _token = 0;

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      heartbeat.transportCapabilityObservations;

  @override
  Stream<TransportRouteProofObservation> get routeProofObservations =>
      heartbeat.routeProofObservations;

  @override
  void setRouteProofProvider(TransportRouteProofProvider? provider) =>
      heartbeat.setRouteProofProvider(provider);

  Future<void> challenge(_ProofTransfer peer, {bool forge = false}) async {
    final token = ++_token;
    final ping = await heartbeat.encodePing(
      token: token,
      lastTxSeq: 0,
      lastRxSeq: 0,
      audioRxPackets: 0,
    );
    final decodedPing = peer.heartbeat.decodeControl(ping, address)!;
    var pong = await peer.heartbeat.encodePong(
      token: decodedPing.packet.token,
      lastTxSeq: 0,
      lastRxSeq: 0,
      audioRxPackets: 0,
      challengeEpoch: decodedPing.packet.sessionEpoch,
    );
    if (forge) {
      final genuine = RoomMemberTransportProof.decode(
        heartbeat.decodeControl(pong, peer.address)!.routeProof!,
      );
      final signature = [...genuine.memberSignature];
      signature[0] ^= 1;
      final forged = RoomMemberTransportProof(
        certificate: genuine.certificate,
        token: genuine.token,
        sessionEpoch: genuine.sessionEpoch,
        memberSignature: signature,
        name: genuine.name,
      );
      pong = peer.heartbeat.codec.encodePong(
        token: token,
        lastTxSeq: 0,
        lastRxSeq: 0,
        audioRxPackets: 0,
        routeProof: forged.encode(),
      );
    }
    final decodedPong = heartbeat.decodeControl(pong, peer.address)!;
    expect(decodedPong.packet.token, token);
    heartbeat.observeMatchedPong(
      decoded: decodedPong,
      peerKey: peer.address,
      observedAt: DateTime.now(),
      challengeEpoch: epoch.value,
    );
  }
}

class _RoomRepository implements RoomRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  _RoomRepository({this.selected, this.selectedFuture, this.saved});

  final RoomId? selected;
  final Future<RoomId?>? selectedFuture;
  final SavedRoom? saved;

  @override
  Future<RoomId?> selectedRoomId() async =>
      selectedFuture == null ? selected : await selectedFuture;

  @override
  Future<SavedRoom?> get(RoomId id) async =>
      id == (selected ?? id) ? saved : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _TransferRepository
    implements TransferRepository, ConnectionHealthSnapshot {
  _TransferRepository({this.role = SessionRole.unknown, this.currentHealth});

  final SessionRole role;
  final ConnectionHealth? currentHealth;
  final StreamController<ConnectionHealth> health =
      StreamController<ConnectionHealth>.broadcast(sync: true);
  int connectCalls = 0;

  @override
  SessionRole get sessionRole => role;

  @override
  ConnectionHealth? get currentConnectionHealth => currentHealth;

  @override
  Stream<ConnectionHealth> connect() {
    connectCalls++;
    return health.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _ModeStore implements TransferModeStore {
  _ModeStore(this.current);

  final TransferMode current;

  @override
  TransferMode get mode => current;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _HotspotHost implements HotspotHost {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _HotspotLinkKeeper implements HotspotLinkKeeper {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _IdentityStore implements RoomTransportIdentitySecureStore {
  RoomTransportIdentityMaterial? value;

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => value;

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    value = material;
  }

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    value = null;
  }
}
