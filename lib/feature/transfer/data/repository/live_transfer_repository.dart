import 'dart:async';

import 'package:dartz/dartz.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../../../../core/error/failure.dart';
import '../../domain/entity/audio_profile.dart';
import '../../domain/entity/connection_health.dart';
import '../../domain/entity/session_role.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/entity/carrier_handover_observation.dart';
import '../../domain/entity/transport_capability_observation.dart';
import '../../domain/entity/transport_route_proof_observation.dart';
import '../../domain/entity/transport_stats.dart';
import '../../domain/entity/waki_packet.dart';
import '../../domain/repository/transfer_repository.dart';
import '../../domain/repository/carrier_handover_exchange.dart';
import '../../domain/repository/transport_capability_observation_source.dart';
import '../../domain/repository/transport_route_proof_exchange.dart';
import '../../domain/service/transfer_mode_store.dart';

/// Session-scoped transport attachment that follows the effective transfer mode.
///
/// Historically `TransferRepository` was selected once when `WalkieTalkieCubit`
/// was constructed. Updating [TransferModeStore.mode] during a live Room could
/// therefore leave the Cubit sending on the old repository even though Room
/// failover had selected a replacement transport. This adapter keeps the Cubit
/// instance stable while replacing only its temporary transport attachment.
///
/// Wi-Fi and hotspot deliberately resolve to the same repository: hotspot is a
/// setup role for the same live Wi-Fi transport, so switching between those two
/// modes must not tear down a healthy socket set. A real repository change
/// stops the previous connection and rebinds any already-consumed packet,
/// health, capability-observation, and route-proof streams to the replacement.
/// Generation guards make delayed stream cancellation from an older switch
/// unable to attach a stale repository.
///
/// Capability observations and route proofs remain optional and fail closed.
/// If the active concrete transport does not expose the relevant interface,
/// this wrapper emits no evidence rather than fabricating it. The route-proof
/// provider is explicitly detached from the old transport before mode
/// replacement so local member credentials cannot remain active on a stale
/// attachment.
///
/// The concrete repositories are application singletons and are not owned by
/// this wrapper. [stopConnection] is the live-session ownership boundary used by
/// `WalkieTalkieCubit.close`; it stops the active attachment and releases this
/// wrapper's mode/packet/health/capability/proof subscriptions without disposing
/// those shared repositories.
final class LiveTransferRepository
    implements
        TransferRepository,
        TransportCapabilityObservationSource,
        TransportRouteProofExchange,
        CarrierHandoverExchange {
  LiveTransferRepository({
    required TransferModeStore modeStore,
    required TransferRepository wifi,
    required TransferRepository bluetooth,
    required TransferRepository guest,
  }) : _modeStore = modeStore,
       _wifi = wifi,
       _bluetooth = bluetooth,
       _guest = guest,
       _active = _select(modeStore.mode, wifi, bluetooth, guest) {
    _modeSubscription = _modeStore.modeChanges.listen(_onModeChanged);
  }

  final TransferModeStore _modeStore;
  final TransferRepository _wifi;
  final TransferRepository _bluetooth;
  final TransferRepository _guest;

  late TransferRepository _active;
  late final StreamSubscription<TransferMode> _modeSubscription;

  final _packetController = StreamController<WakiPacket>.broadcast();
  final _healthController = StreamController<ConnectionHealth>.broadcast();
  final _capabilityController =
      StreamController<TransportCapabilityObservation>.broadcast();
  final _routeProofController =
      StreamController<TransportRouteProofObservation>.broadcast();
  StreamSubscription<WakiPacket>? _packetSubscription;
  StreamSubscription<ConnectionHealth>? _healthSubscription;
  StreamSubscription<TransportCapabilityObservation>? _capabilitySubscription;
  StreamSubscription<TransportRouteProofObservation>? _routeProofSubscription;
  TransportRouteProofProvider? _routeProofProvider;
  final _carrierHandoverController =
      StreamController<CarrierHandoverObservation>.broadcast();
  StreamSubscription<CarrierHandoverObservation>? _carrierHandoverSubscription;
  CarrierHandoverProvider? _carrierHandoverProvider;
  bool _packetsRequested = false;
  bool _healthRequested = false;
  bool _capabilitiesRequested = false;
  bool _routeProofsRequested = false;
  bool _carrierHandoversRequested = false;
  bool _disposed = false;
  int _attachmentGeneration = 0;

  static TransferRepository _select(
    TransferMode mode,
    TransferRepository wifi,
    TransferRepository bluetooth,
    TransferRepository guest,
  ) => switch (mode) {
    TransferMode.bluetooth => bluetooth,
    TransferMode.guest => guest,
    TransferMode.hotspot || TransferMode.wifi => wifi,
  };

  static TransportCapabilityObservationSource? _capabilitySource(
    Object repository,
  ) => repository is TransportCapabilityObservationSource ? repository : null;

  static TransportRouteProofExchange? _routeProofExchange(Object repository) =>
      repository is TransportRouteProofExchange ? repository : null;

  static CarrierHandoverExchange? _carrierHandoverExchange(Object repository) =>
      repository is CarrierHandoverExchange ? repository : null;

  TransferRepository get _current =>
      _select(_modeStore.mode, _wifi, _bluetooth, _guest);

  void _onModeChanged(TransferMode mode) {
    if (_disposed) return;
    final next = _select(mode, _wifi, _bluetooth, _guest);
    if (identical(next, _active)) return;

    final previous = _active;
    final previousProofExchange = _routeProofExchange(previous);
    previousProofExchange?.setRouteProofProvider(null);
    // Cleared before the swap for the same reason the proof provider is: the
    // outgoing transport must stop announcing a carrier the moment it stops
    // being the one the Room is on, or it keeps telling peers to move onto a
    // network it is no longer bringing them to.
    _carrierHandoverExchange(previous)?.setCarrierHandoverProvider(null);
    _active = next;
    final generation = ++_attachmentGeneration;

    // The old attachment must stop before its replacement owns the live
    // session. This does not dispose the singleton repository, so a later
    // explicit mode selection can use it again.
    previous.stopConnection();

    _routeProofExchange(next)?.setRouteProofProvider(_routeProofProvider);
    _carrierHandoverExchange(
      next,
    )?.setCarrierHandoverProvider(_carrierHandoverProvider);

    if (_packetsRequested) {
      unawaited(_rebindPackets(next, generation));
    }
    if (_healthRequested) {
      unawaited(_rebindHealth(next, generation));
    }
    if (_capabilitiesRequested) {
      unawaited(_rebindCapabilities(next, generation));
    }
    if (_carrierHandoversRequested) {
      unawaited(_rebindCarrierHandovers(next, generation));
    }
    if (_routeProofsRequested) {
      unawaited(_rebindRouteProofs(next, generation));
    }
  }

  Future<void> _rebindPackets(
    TransferRepository repository,
    int generation,
  ) async {
    final previous = _packetSubscription;
    _packetSubscription = null;
    await previous?.cancel();
    if (_disposed || generation != _attachmentGeneration) return;
    _packetSubscription = repository.startListening().listen(
      _packetController.add,
      onError: _packetController.addError,
    );
  }

  Future<void> _rebindHealth(
    TransferRepository repository,
    int generation,
  ) async {
    final previous = _healthSubscription;
    _healthSubscription = null;
    await previous?.cancel();
    if (_disposed || generation != _attachmentGeneration) return;
    _healthSubscription = repository.connect().listen(
      _healthController.add,
      onError: _healthController.addError,
    );
  }

  Future<void> _rebindCapabilities(
    TransferRepository repository,
    int generation,
  ) async {
    final previous = _capabilitySubscription;
    _capabilitySubscription = null;
    await previous?.cancel();
    if (_disposed || generation != _attachmentGeneration) return;
    final source = _capabilitySource(repository);
    if (source == null) return;
    _capabilitySubscription = source.transportCapabilityObservations.listen(
      _capabilityController.add,
      onError: _capabilityController.addError,
    );
  }

  Future<void> _rebindRouteProofs(
    TransferRepository repository,
    int generation,
  ) async {
    final previous = _routeProofSubscription;
    _routeProofSubscription = null;
    await previous?.cancel();
    if (_disposed || generation != _attachmentGeneration) return;
    final exchange = _routeProofExchange(repository);
    if (exchange == null) return;
    _routeProofSubscription = exchange.routeProofObservations.listen(
      _routeProofController.add,
      onError: _routeProofController.addError,
    );
  }

  @override
  Stream<WakiPacket> startListening() {
    if (_disposed) return const Stream<WakiPacket>.empty();
    _packetsRequested = true;
    _packetSubscription ??= _current.startListening().listen(
      _packetController.add,
      onError: _packetController.addError,
    );
    _active = _current;
    return _packetController.stream;
  }

  @override
  Stream<ConnectionHealth> connect() {
    if (_disposed) return const Stream<ConnectionHealth>.empty();
    _healthRequested = true;
    _healthSubscription ??= _current.connect().listen(
      _healthController.add,
      onError: _healthController.addError,
    );
    _active = _current;
    return _healthController.stream;
  }

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations {
    if (_disposed) return const Stream<TransportCapabilityObservation>.empty();
    _capabilitiesRequested = true;
    final current = _current;
    final source = _capabilitySource(current);
    if (_capabilitySubscription == null && source != null) {
      _capabilitySubscription = source.transportCapabilityObservations.listen(
        _capabilityController.add,
        onError: _capabilityController.addError,
      );
    }
    _active = current;
    return _capabilityController.stream;
  }

  @override
  Stream<TransportRouteProofObservation> get routeProofObservations {
    if (_disposed) return const Stream<TransportRouteProofObservation>.empty();
    _routeProofsRequested = true;
    final current = _current;
    final exchange = _routeProofExchange(current);
    if (_routeProofSubscription == null && exchange != null) {
      _routeProofSubscription = exchange.routeProofObservations.listen(
        _routeProofController.add,
        onError: _routeProofController.addError,
      );
    }
    exchange?.setRouteProofProvider(_routeProofProvider);
    _active = current;
    return _routeProofController.stream;
  }

  @override
  void setRouteProofProvider(TransportRouteProofProvider? provider) {
    if (_disposed) return;
    _routeProofProvider = provider;
    _routeProofExchange(_current)?.setRouteProofProvider(provider);
  }

  @override
  Stream<CarrierHandoverObservation> get carrierHandoverObservations {
    if (_disposed) return const Stream<CarrierHandoverObservation>.empty();
    _carrierHandoversRequested = true;
    final current = _current;
    final exchange = _carrierHandoverExchange(current);
    if (_carrierHandoverSubscription == null && exchange != null) {
      _carrierHandoverSubscription = exchange.carrierHandoverObservations
          .listen(
            _carrierHandoverController.add,
            onError: _carrierHandoverController.addError,
          );
    }
    exchange?.setCarrierHandoverProvider(_carrierHandoverProvider);
    _active = current;
    return _carrierHandoverController.stream;
  }

  @override
  void setCarrierHandoverProvider(CarrierHandoverProvider? provider) {
    if (_disposed) return;
    _carrierHandoverProvider = provider;
    _carrierHandoverExchange(_current)?.setCarrierHandoverProvider(provider);
  }

  Future<void> _rebindCarrierHandovers(
    TransferRepository repository,
    int generation,
  ) async {
    final previous = _carrierHandoverSubscription;
    _carrierHandoverSubscription = null;
    await previous?.cancel();
    if (_disposed || generation != _attachmentGeneration) return;
    final exchange = _carrierHandoverExchange(repository);
    if (exchange == null) return;
    _carrierHandoverSubscription = exchange.carrierHandoverObservations.listen(
      _carrierHandoverController.add,
      onError: _carrierHandoverController.addError,
    );
  }

  @override
  AudioFormatProfile get negotiatedFormat => _current.negotiatedFormat;

  @override
  AudioFormatProfile? get negotiatedMediaFormat =>
      _current.negotiatedMediaFormat;

  @override
  SessionRole get sessionRole => _current.sessionRole;

  @override
  TransportStats get stats => _current.stats;

  @override
  Future<Either<Failure, void>> sendAudio(
    List<double> samples,
    String senderName,
  ) => _current.sendAudio(samples, senderName);

  @override
  Future<Either<Failure, void>> sendMedia(
    List<double> samples,
    String senderName,
  ) => _current.sendMedia(samples, senderName);

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) => _current.sendPresence(senderName, isTalking, isLeaving: isLeaving);

  @override
  void setAudioProfile(AudioProfile profile) =>
      _current.setAudioProfile(profile);

  @override
  void setAutoReconnectEnabled(bool enabled) =>
      _current.setAutoReconnectEnabled(enabled);

  @override
  void retryNow() => _current.retryNow();

  @override
  void resetCodecState() => _current.resetCodecState();

  @override
  void repairSendPath() => _current.repairSendPath();

  @override
  void stopConnection() {
    if (_disposed) return;
    _routeProofExchange(_active)?.setRouteProofProvider(null);
    _carrierHandoverExchange(_active)?.setCarrierHandoverProvider(null);
    _routeProofProvider = null;
    _active.stopConnection();
    _disposed = true;
    ++_attachmentGeneration;
    unawaited(_disposeAsync());
  }

  @override
  void dispose() => stopConnection();

  Future<void> _disposeAsync() async {
    await _modeSubscription.cancel();
    await _packetSubscription?.cancel();
    await _healthSubscription?.cancel();
    await _capabilitySubscription?.cancel();
    await _routeProofSubscription?.cancel();
    await _carrierHandoverSubscription?.cancel();
    await _packetController.close();
    await _healthController.close();
    await _capabilityController.close();
    await _routeProofController.close();
    await _carrierHandoverController.close();
  }
}
