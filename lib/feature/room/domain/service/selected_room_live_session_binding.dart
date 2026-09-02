import 'dart:async';

import '../../../transfer/api/transfer_api.dart';
import '../../data/security/room_transport_identity_lifecycle.dart';
import '../../data/security/room_transport_identity_secure_store.dart';
import '../entity/transport_attachment.dart';
import '../repository/room_repository.dart';
import 'room_capability_failover_runtime.dart';
import 'room_carrier_promotion_controller.dart';
import 'room_failover_controller.dart';
import 'room_failover_runtime.dart';
import 'room_failover_transport_orchestrator.dart';
import 'room_live_failover_transport_starter.dart';
import 'room_member_transport_identity.dart';
import 'room_pending_seat_confirmer.dart';
import 'room_session_factory.dart';
import 'room_session_runtime.dart';
import 'room_transport_health_runtime_adapter.dart';
import 'room_verified_transport_capability_runtime.dart';
import 'room_verified_transport_evidence_bridge.dart';

/// Application-facing binding used only when the user actually enters a live
/// channel. Merely viewing/selecting a saved Room never calls this class and
/// therefore cannot start or attach transport state as a side effect.
///
/// The selected durable Room remains the logical identity while the current
/// transport's existing health stream drives only [TransportAttachment]
/// lifecycle. `TransferRepository.connect()` is a broadcast health stream for
/// the active transport; this binding does not start a second connection.
final class SelectedRoomLiveSessionBinding {
  SelectedRoomLiveSessionBinding({
    required this.rooms,
    required this.transfer,
    required this.modeStore,
    this.hotspotHost,
    this.hotspotLinkKeeper,
    this.localCapabilityReader,
    RoomTransportIdentitySecureStore? identityStore,
    RoomMemberTransportIdentityCrypto? identityCrypto,
  }) : _identityStore =
           identityStore ?? PlatformRoomTransportIdentitySecureStore(),
       _identityCrypto = identityCrypto ?? RoomMemberTransportIdentityCrypto();

  final RoomRepository rooms;
  final TransferRepository transfer;
  final TransferModeStore modeStore;

  /// Production supplies both transport seams from DI. Keeping them optional
  /// preserves non-Android/test composition without fabricating host ability.
  final HotspotHost? hotspotHost;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final Future<TransportCapabilityAdvertisement?> Function()?
  localCapabilityReader;
  final RoomTransportIdentitySecureStore _identityStore;
  final RoomMemberTransportIdentityCrypto _identityCrypto;

  RoomSessionRuntime? _runtime;
  _LiveFailoverSession? _failover;
  RoomCarrierPromotionController? _carrierPromotion;
  int _generation = 0;

  RoomSessionRuntime? get runtime => _runtime;

  /// Live view of which network this Room is on and whether it is being moved.
  ///
  /// Null until a session is open, and on any composition that cannot support
  /// a handover — Bluetooth, the guest link, a device with no signing
  /// material. A null here means "no promotion machinery", never "settled".
  RoomCarrierPromotionController? get carrierPromotion => _carrierPromotion;

  Future<RoomSessionRuntime?> open({required String sessionId}) async {
    final generation = ++_generation;
    await _closeCurrent();

    final selectedId = await rooms.selectedRoomId();
    if (generation != _generation || selectedId == null) return null;
    final saved = await rooms.get(selectedId);
    if (generation != _generation || saved == null) return null;

    final runtime = RoomSessionFactory.open(saved, sessionId: sessionId);
    if (runtime == null) return null;

    // LiveTransferRepository exposes a broadcast stream that follows mode
    // replacement. Reuse this single surface for lifecycle and failover
    // detection rather than opening another transport connection.
    final health = transfer.connect();
    final adapter = RoomTransportHealthRuntimeAdapter(runtime);
    await adapter.attach(
      kind: transportKindFor(modeStore.mode),
      health: health,
      role: transfer.sessionRole == SessionRole.unknown
          ? null
          : transfer.sessionRole.name,
      reason: 'live_entry',
    );

    final host = hotspotHost;
    final keeper = hotspotLinkKeeper;
    _LiveFailoverSession? failover;
    RoomCarrierPromotionController? carrierPromotion;
    if (host != null && keeper != null) {
      // Existing owner Rooms are provisioned lazily; joined members must
      // already have persisted material from accepted secure join. If an
      // ordinary member's secure material is unavailable, failover stays off
      // rather than falling back to network metadata as identity.
      RoomTransportIdentityMaterial? identity;
      try {
        identity = await RoomTransportIdentityLifecycle(
          store: _identityStore,
          crypto: _identityCrypto,
        ).ensureLocalIdentity(saved);
      } on Object {
        identity = null;
      }

      if (generation != _generation) {
        await runtime.leave();
        return null;
      }

      final identityMaterial = identity;
      if (identityMaterial != null) {
        final failoverRuntime = RoomFailoverRuntime(session: runtime);
        // Built before the promotion controller exists, so the callback
        // resolves it lazily through the local rather than capturing a null.
        final starter = RoomLiveFailoverTransportStarter(
          localMemberId: saved.membership.localMemberId,
          modeStore: modeStore,
          transfer: transfer,
          hotspotHost: host,
          hotspotLinkKeeper: keeper,
          onHotspotRaised: (credentials) async =>
              carrierPromotion?.announceRaisedCarrier(credentials),
        );
        final orchestrator = RoomFailoverTransportOrchestrator(
          runtime: failoverRuntime,
          startTransport: starter.call,
        );
        final capabilities = RoomCapabilityFailoverRuntime(
          orchestrator: orchestrator,
        );
        final verified = RoomVerifiedTransportCapabilityRuntime(
          capability: capabilities,
          expectedIssuerPublicKey: identityMaterial.certificate.issuerPublicKey,
        );
        failover = _LiveFailoverSession(
          verified: verified,
          orchestrator: orchestrator,
          // The roster's other half. An invite seat has to be opened before
          // anyone can scan it, so it starts as a placeholder nobody has
          // claimed; R7 clears it when the joiner opens the Room screen and
          // writes their name. A rider who joins and simply rides never does
          // that, so the seat stays "open" for someone the host is talking to.
          // A verified route proof settles it without anyone tapping anything.
          seats: RoomPendingSeatConfirmer(rooms: rooms, roomId: saved.room.id),
          readLocalCapability:
              localCapabilityReader ?? TransportCapabilityReader.current,
          localProofProvider:
              ({required int token, required int challengeEpoch}) async {
                final proof = await _identityCrypto.signProof(
                  certificate: identityMaterial.certificate,
                  member: identityMaterial.memberKeyPair,
                  token: token,
                  sessionEpoch: challengeEpoch,
                );
                return proof.encode();
              },
        );
        await failover.start(health: health, transfer: transfer);

        // The pre-emptive half. Failover above reacts to a carrier that has
        // already died; this moves the Room off a borrowed one while it is
        // still alive, which is the only moment a handover can actually be
        // delivered to the peers who have to follow it.
        final handoverExchange = transfer is CarrierHandoverExchange
            ? transfer as CarrierHandoverExchange
            : null;
        if (handoverExchange != null) {
          final promotion = RoomCarrierPromotionController(
            localMemberId: saved.membership.localMemberId,
            roomId: saved.room.id,
            issuerPublicKey: identityMaterial.certificate.issuerPublicKey,
            modeStore: modeStore,
            hotspotHost: host,
            hotspotLinkKeeper: keeper,
            handoverExchange: handoverExchange,
            identity: identityMaterial,
            crypto: _identityCrypto,
            // Only peers whose capability evidence has been cryptographically
            // bound to a durable member reach the election. An unverified
            // observation could otherwise nominate a stranger to run the whole
            // Room's network.
            candidates: () => capabilities.candidates.snapshot(
              now: DateTime.now(),
              attachmentGeneration: capabilities.attachmentGeneration,
            ),
          );
          failover.carrierPromotion = promotion;
          promotion.start();
          carrierPromotion = promotion;
        }
      }
    }

    if (generation != _generation) {
      await carrierPromotion?.dispose();
      await failover?.dispose();
      await runtime.leave();
      return null;
    }
    _runtime = runtime;
    _failover = failover;
    _carrierPromotion = carrierPromotion;
    return runtime;
  }

  Future<void> close() async {
    _generation++;
    await _closeCurrent();
  }

  Future<void> _closeCurrent() async {
    final failover = _failover;
    final promotion = _carrierPromotion;
    final current = _runtime;
    _failover = null;
    _carrierPromotion = null;
    _runtime = null;
    // Before the failover session: disposing this clears the announcement
    // provider, and a Room that has stopped must not still be telling peers to
    // move onto a network it is about to take down.
    await promotion?.dispose();
    await failover?.dispose();
    if (current != null && !current.hasLeft) await current.leave();
  }

  static TransportKind transportKindFor(TransferMode mode) => switch (mode) {
    TransferMode.wifi => TransportKind.wifi,
    TransferMode.hotspot => TransportKind.hotspot,
    TransferMode.bluetooth => TransportKind.bluetooth,
    TransferMode.guest => TransportKind.webrtc,
  };
}

/// Owns only the failover lifetime underneath one logical Room session.
///
/// Remote capability observations remain unusable until a cryptographically
/// verified live route proof binds the carrier-observed peer key to an active
/// RoomMemberId. No IP, senderId, SSID, channel id or device/display name is
/// treated as Room identity.
final class _LiveFailoverSession {
  _LiveFailoverSession({
    required this.verified,
    required this.orchestrator,
    required this.seats,
    required this.readLocalCapability,
    required this.localProofProvider,
  });

  final RoomVerifiedTransportCapabilityRuntime verified;
  final RoomFailoverTransportOrchestrator orchestrator;
  final RoomPendingSeatConfirmer seats;
  final Future<TransportCapabilityAdvertisement?> Function()
  readLocalCapability;
  final TransportRouteProofProvider localProofProvider;

  RoomVerifiedTransportEvidenceBridge? _evidenceBridge;
  StreamSubscription<ConnectionHealth>? _healthSubscription;
  int? _handledDownGeneration;
  bool _disposed = false;

  /// Set once the promotion controller exists, so refreshed local evidence can
  /// poke it. A second phone appearing is exactly the event that turns "a Room
  /// of one, nothing to do" into "time to move", and waiting up to a full tick
  /// for it would be waiting for no reason.
  RoomCarrierPromotionController? carrierPromotion;

  Future<void> start({
    required Stream<ConnectionHealth> health,
    required TransferRepository transfer,
  }) async {
    final TransportCapabilityObservationSource? capabilitySource =
        transfer is TransportCapabilityObservationSource
        ? transfer as TransportCapabilityObservationSource
        : null;
    final TransportRouteProofExchange? proofExchange =
        transfer is TransportRouteProofExchange
        ? transfer as TransportRouteProofExchange
        : null;
    if (capabilitySource != null && proofExchange != null) {
      _evidenceBridge = RoomVerifiedTransportEvidenceBridge(
        runtime: verified,
        capabilitySource: capabilitySource,
        proofExchange: proofExchange,
        localProofProvider: localProofProvider,
        // Fire-and-forget on purpose: settling a roster row is bookkeeping,
        // and the proof path it hangs off is on the way to admitting live
        // capability evidence. A storage write must not be able to delay that,
        // and the confirmer already swallows its own failures.
        onMemberProven: (memberId) => unawaited(seats.confirm(memberId)),
      );
    }
    _healthSubscription = health.listen(
      _onHealth,
      onError: (Object _) => _requestFailover(),
      onDone: _requestFailover,
    );
    await _refreshLocalEvidence();
  }

  void _onHealth(ConnectionHealth health) {
    if (health.status == ConnectionHealthStatus.down) _requestFailover();
  }

  void _requestFailover() {
    if (_disposed) return;
    unawaited(_beginFailoverIfCurrent());
  }

  Future<void> _beginFailoverIfCurrent() async {
    if (_disposed) return;
    final generation = verified.attachmentGeneration;
    if (_handledDownGeneration == generation) return;
    _handledDownGeneration = generation;

    await _refreshLocalEvidence(expectedGeneration: generation);
    if (_disposed || verified.attachmentGeneration != generation) return;

    await verified.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.transportFailed,
      now: DateTime.now(),
    );
    if (verified.attachmentGeneration != generation) {
      _evidenceBridge?.clearPending();
    }
  }

  Future<void> _refreshLocalEvidence({int? expectedGeneration}) async {
    final capability = await readLocalCapability();
    if (_disposed || capability == null) return;
    if (expectedGeneration != null &&
        verified.attachmentGeneration != expectedGeneration) {
      return;
    }
    carrierPromotion?.evaluate();
    verified.observeLocal(
      canHostHotspot: capability.canHostHotspot,
      bluetoothSupported: capability.bluetoothSupported,
      backgroundReady: capability.backgroundReady,
      batteryPercent: capability.batteryPercent,
      prefersHotspotHost: capability.prefersHotspotHost,
      at: DateTime.now(),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    seats.dispose();
    await _healthSubscription?.cancel();
    await _evidenceBridge?.dispose();
    await orchestrator.cancel();
    verified.dispose();
  }
}
