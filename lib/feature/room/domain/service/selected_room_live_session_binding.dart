import 'dart:async';

import '../../../transfer/api/transfer_api.dart';
import '../entity/transport_attachment.dart';
import '../repository/room_repository.dart';
import 'room_capability_failover_runtime.dart';
import 'room_failover_controller.dart';
import 'room_failover_runtime.dart';
import 'room_failover_transport_orchestrator.dart';
import 'room_live_failover_transport_starter.dart';
import 'room_session_factory.dart';
import 'room_session_runtime.dart';
import 'room_transport_capability_observation_bridge.dart';
import 'room_transport_health_runtime_adapter.dart';

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
  });

  final RoomRepository rooms;
  final TransferRepository transfer;
  final TransferModeStore modeStore;

  /// Production supplies both transport seams from DI. Keeping them optional
  /// preserves non-Android/test composition without fabricating host ability.
  final HotspotHost? hotspotHost;
  final HotspotLinkKeeper? hotspotLinkKeeper;
  final Future<TransportCapabilityAdvertisement?> Function()?
  localCapabilityReader;

  RoomSessionRuntime? _runtime;
  _LiveFailoverSession? _failover;
  int _generation = 0;

  RoomSessionRuntime? get runtime => _runtime;

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
    if (host != null && keeper != null) {
      final failoverRuntime = RoomFailoverRuntime(session: runtime);
      final starter = RoomLiveFailoverTransportStarter(
        localMemberId: saved.membership.localMemberId,
        modeStore: modeStore,
        transfer: transfer,
        hotspotHost: host,
        hotspotLinkKeeper: keeper,
      );
      final orchestrator = RoomFailoverTransportOrchestrator(
        runtime: failoverRuntime,
        startTransport: starter.call,
      );
      final capabilities = RoomCapabilityFailoverRuntime(
        orchestrator: orchestrator,
      );
      failover = _LiveFailoverSession(
        capabilities: capabilities,
        orchestrator: orchestrator,
        readLocalCapability:
            localCapabilityReader ?? TransportCapabilityReader.current,
      );
      await failover.start(health: health, transfer: transfer);
    }

    if (generation != _generation) {
      await failover?.dispose();
      await runtime.leave();
      return null;
    }
    _runtime = runtime;
    _failover = failover;
    return runtime;
  }

  Future<void> close() async {
    _generation++;
    await _closeCurrent();
  }

  Future<void> _closeCurrent() async {
    final failover = _failover;
    final current = _runtime;
    _failover = null;
    _runtime = null;
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
/// verified peer-to-member binding exists in [RoomCapabilityFailoverRuntime].
/// This composition never derives RoomMemberId from IP, senderId, SSID or a
/// device/display name. Local evidence comes only from the platform capability
/// reader; missing evidence means no fabricated election candidate.
final class _LiveFailoverSession {
  _LiveFailoverSession({
    required this.capabilities,
    required this.orchestrator,
    required this.readLocalCapability,
  });

  final RoomCapabilityFailoverRuntime capabilities;
  final RoomFailoverTransportOrchestrator orchestrator;
  final Future<TransportCapabilityAdvertisement?> Function()
  readLocalCapability;

  RoomTransportCapabilityObservationBridge? _bridge;
  StreamSubscription<ConnectionHealth>? _healthSubscription;
  int? _handledDownGeneration;
  bool _disposed = false;

  Future<void> start({
    required Stream<ConnectionHealth> health,
    required TransferRepository transfer,
  }) async {
    final source = transfer;
    if (source is TransportCapabilityObservationSource) {
      _bridge = RoomTransportCapabilityObservationBridge(
        runtime: capabilities,
        source: source,
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
    final generation = capabilities.attachmentGeneration;
    if (_handledDownGeneration == generation) return;
    _handledDownGeneration = generation;

    await _refreshLocalEvidence(expectedGeneration: generation);
    if (_disposed || capabilities.attachmentGeneration != generation) return;

    await capabilities.beginFailover(
      sharedLanUsable: false,
      reason: RoomFailoverReason.transportFailed,
      now: DateTime.now(),
    );
  }

  Future<void> _refreshLocalEvidence({int? expectedGeneration}) async {
    final capability = await readLocalCapability();
    if (_disposed || capability == null) return;
    if (expectedGeneration != null &&
        capabilities.attachmentGeneration != expectedGeneration) {
      return;
    }
    capabilities.observeLocal(
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
    await _healthSubscription?.cancel();
    await _bridge?.dispose();
    await orchestrator.cancel();
    capabilities.dispose();
  }
}
