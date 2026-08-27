import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entity/transport_capability_advertisement.dart';
import '../../domain/entity/transport_capability_observation.dart';
import '../../domain/entity/transport_route_proof_observation.dart';
import '../../domain/repository/transport_capability_observation_source.dart';
import '../../domain/repository/transport_route_proof_exchange.dart';
import '../capability/transport_capability_reader.dart';
import 'transport_capability_control_codec.dart';
import 'transport_route_proof_wire.dart';

typedef TransportCapabilitySnapshotReader =
    Future<TransportCapabilityAdvertisement?> Function();

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

  void observeMatchedPong({
    required DecodedTransportCapabilityControl decoded,
    required String peerKey,
    required DateTime observedAt,
    int? challengeEpoch,
  }) {
    // [peerKey] is only the caller's witness that it matched/admitted this Pong.
    // Attribution must remain the locally captured carrier route on [decoded].
    // Requiring those two strings to be equal makes a payload sender id passed
    // by an older caller silently suppress otherwise valid capability evidence.
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
      return null;
    }
  }

  Future<String?> _safeReadRouteProof(int token, int? challengeEpoch) async {
    final provider = _routeProofProvider;
    if (_disposed || provider == null || challengeEpoch == null) return null;
    try {
      final proof = await provider(
        token: token,
        challengeEpoch: challengeEpoch,
      );
      if (proof == null) return null;
      final encodedLength = utf8.encode(proof).length;
      if (encodedLength == 0 ||
          encodedLength > TransportRouteProofWire.maxProofBytes) {
        return null;
      }
      return proof;
    } catch (_) {
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
