import 'dart:async';
import 'dart:typed_data';

import '../../domain/entity/transport_capability_advertisement.dart';
import '../../domain/entity/transport_capability_observation.dart';
import '../../domain/entity/transport_route_proof_observation.dart';
import '../../domain/repository/transport_capability_observation_source.dart';
import '../../domain/repository/transport_route_proof_exchange.dart';
import '../capability/transport_capability_reader.dart';
import 'transport_capability_control_codec.dart';

typedef TransportCapabilitySnapshotReader =
    Future<TransportCapabilityAdvertisement?> Function();

/// Session-scoped bridge between truthful local capability evidence and the
/// existing mixed-version-safe control heartbeat.
///
/// It owns no timer: callers sample it only on their existing heartbeat cadence.
/// Remote capability and opaque Room proof bytes are exposed only through
/// [observeMatchedPong], after the Wi-Fi caller independently matches the Pong
/// source route and token. Decoding a trailer alone therefore grants nothing.
final class TransportCapabilityHeartbeatRuntime
    implements
        TransportCapabilityObservationSource,
        TransportRouteProofExchange {
  TransportCapabilityHeartbeatRuntime({
    required this.codec,
    TransportCapabilitySnapshotReader? readLocalCapability,
  }) : _readLocalCapability =
           readLocalCapability ?? TransportCapabilityReader.current;

  final TransportCapabilityControlCodec codec;
  final TransportCapabilitySnapshotReader _readLocalCapability;
  final _observations =
      StreamController<TransportCapabilityObservation>.broadcast(sync: true);
  final _routeProofObservations =
      StreamController<TransportRouteProofObservation>.broadcast(sync: true);
  TransportRouteProofProvider? _routeProofProvider;
  bool _disposed = false;

  @override
  Stream<TransportCapabilityObservation> get transportCapabilityObservations =>
      _observations.stream;

  @override
  Stream<TransportRouteProofObservation> get routeProofObservations =>
      _routeProofObservations.stream;

  @override
  void setRouteProofProvider(TransportRouteProofProvider? provider) {
    if (_disposed) return;
    _routeProofProvider = provider;
  }

  Future<Uint8List> encodePing({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
  }) async => codec.encodePing(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    capability: await _safeReadLocalCapability(),
  );

  Future<Uint8List> encodePong({
    required int token,
    required int lastTxSeq,
    required int lastRxSeq,
    required int audioRxPackets,
    int? challengeEpoch,
  }) async => codec.encodePong(
    token: token,
    lastTxSeq: lastTxSeq,
    lastRxSeq: lastRxSeq,
    audioRxPackets: audioRxPackets,
    capability: await _safeReadLocalCapability(),
    routeProof: await _safeReadRouteProof(token, challengeEpoch),
  );

  DecodedTransportCapabilityControl? decodeControl(
    Uint8List bytes,
    String fallbackSenderId,
  ) => codec.decodeControl(bytes, fallbackSenderId);

  /// Admits optional evidence only after the caller has independently proven
  /// that this decoded packet is the expected Pong for [peerKey].
  ///
  /// [peerKey] remains only the caller's match witness. Downstream attribution
  /// always preserves [DecodedTransportCapabilityControl.carrierPeerKey], which
  /// came from the local receive carrier rather than the payload sender id.
  void observeMatchedPong({
    required DecodedTransportCapabilityControl decoded,
    required String peerKey,
    required DateTime observedAt,
    int? challengeEpoch,
  }) {
    if (_disposed || peerKey.isEmpty || decoded.carrierPeerKey.isEmpty) return;
    final at = observedAt.toUtc();
    final capability = decoded.capability;
    if (capability != null) {
      _observations.add(
        TransportCapabilityObservation(
          peerKey: decoded.carrierPeerKey,
          capability: capability,
          observedAt: at,
        ),
      );
    }

    final routeProof = decoded.routeProof;
    if (routeProof != null && challengeEpoch != null) {
      _routeProofObservations.add(
        TransportRouteProofObservation(
          peerKey: decoded.carrierPeerKey,
          token: decoded.packet.token,
          challengeEpoch: challengeEpoch,
          encodedProof: routeProof,
          observedAt: at,
        ),
      );
    }
  }

  Future<TransportCapabilityAdvertisement?> _safeReadLocalCapability() async {
    if (_disposed) return null;
    try {
      return await _readLocalCapability();
    } catch (_) {
      // Capability evidence is optional. A platform/read failure remains
      // unknown instead of blocking the heartbeat or fabricating defaults.
      return null;
    }
  }

  Future<String?> _safeReadRouteProof(int token, int? challengeEpoch) async {
    final provider = _routeProofProvider;
    if (_disposed || provider == null || challengeEpoch == null) return null;
    try {
      return await provider(token: token, challengeEpoch: challengeEpoch);
    } catch (_) {
      // Proof is optional at the transport layer. Failure stays unverified and
      // must not block the ordinary heartbeat or invent identity evidence.
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _routeProofProvider = null;
    await _observations.close();
    await _routeProofObservations.close();
  }
}
