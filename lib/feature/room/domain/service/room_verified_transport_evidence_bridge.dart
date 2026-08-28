import 'dart:async';

import '../../../transfer/domain/entity/transport_capability_observation.dart';
import '../../../transfer/domain/entity/transport_route_proof_observation.dart';
import '../../../transfer/domain/repository/transport_capability_observation_source.dart';
import '../../../transfer/domain/repository/transport_route_proof_exchange.dart';
import 'room_verified_transport_capability_runtime.dart';

/// Session-scoped bridge that turns matched live route proof into Room-authorized
/// capability evidence.
///
/// Capability can arrive in the same Pong immediately before its proof. Until
/// that proof verifies, the latest capability for the carrier-observed route is
/// held only as non-authoritative evidence. A valid issuer-certified proof binds
/// the route to a durable Room member, then that pending capability is replayed
/// through [RoomVerifiedTransportCapabilityRuntime]. Forged/unmatched proof can
/// never unlock it.
///
/// The bridge never derives Room identity from IP, senderId, SSID, device name,
/// display name, or channel id. [TransportRouteProofObservation.peerKey] is only
/// an opaque carrier route and gains authority exclusively through the signed
/// proof boundary.
final class RoomVerifiedTransportEvidenceBridge {
  RoomVerifiedTransportEvidenceBridge({
    required this.runtime,
    required TransportCapabilityObservationSource capabilitySource,
    required TransportRouteProofExchange proofExchange,
    required TransportRouteProofProvider localProofProvider,
    this.maxPendingCapabilities = 32,
  }) : _proofExchange = proofExchange,
       assert(maxPendingCapabilities > 0) {
    _proofExchange.setRouteProofProvider(localProofProvider);
    _capabilitySubscription = capabilitySource.transportCapabilityObservations
        .listen(_observeCapability, onError: (Object _) {});
    _proofSubscription = proofExchange.routeProofObservations.listen(
      _queueProof,
      onError: (Object _) {},
    );
  }

  final RoomVerifiedTransportCapabilityRuntime runtime;
  final TransportRouteProofExchange _proofExchange;
  final int maxPendingCapabilities;

  late final StreamSubscription<TransportCapabilityObservation>
  _capabilitySubscription;
  late final StreamSubscription<TransportRouteProofObservation>
  _proofSubscription;
  final Map<String, TransportCapabilityObservation> _pendingCapabilities = {};
  Future<void> _proofTail = Future<void>.value();
  bool _disposed = false;

  int get pendingCapabilityCount => _pendingCapabilities.length;

  void _observeCapability(TransportCapabilityObservation observation) {
    if (_disposed || observation.peerKey.isEmpty) return;
    if (_admitCapability(observation)) {
      _pendingCapabilities.remove(observation.peerKey);
      return;
    }

    _pendingCapabilities.remove(observation.peerKey);
    _pendingCapabilities[observation.peerKey] = observation;
    while (_pendingCapabilities.length > maxPendingCapabilities) {
      _pendingCapabilities.remove(_pendingCapabilities.keys.first);
    }
  }

  bool _admitCapability(TransportCapabilityObservation observation) {
    final capability = observation.capability;
    return runtime.observePeer(
      peerKey: observation.peerKey,
      canHostHotspot: capability.canHostHotspot,
      bluetoothSupported: capability.bluetoothSupported,
      backgroundReady: capability.backgroundReady,
      batteryPercent: capability.batteryPercent,
      at: observation.observedAt,
      prefersHotspotHost: capability.prefersHotspotHost,
    );
  }

  void _queueProof(TransportRouteProofObservation observation) {
    if (_disposed) return;
    // Cryptographic verification is asynchronous. Serialize observations so a
    // later challenge cannot replace the same route's pending token while an
    // earlier proof is still verifying.
    _proofTail = _proofTail
        .then((_) => _verifyProof(observation))
        .catchError((Object _) {});
  }

  Future<void> _verifyProof(TransportRouteProofObservation observation) async {
    if (_disposed || observation.peerKey.isEmpty) return;
    final challenged = runtime.observeChallenge(
      peerKey: observation.peerKey,
      token: observation.token,
      sessionEpoch: observation.challengeEpoch,
      at: observation.observedAt,
    );
    if (!challenged) return;

    final bound = await runtime.verifyAndBind(
      peerKey: observation.peerKey,
      encodedProof: observation.encodedProof,
      at: observation.observedAt,
    );
    if (_disposed || !bound) return;

    final pending = _pendingCapabilities.remove(observation.peerKey);
    if (pending != null) _admitCapability(pending);
  }

  void clearPending() => _pendingCapabilities.clear();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _proofExchange.setRouteProofProvider(null);
    await _capabilitySubscription.cancel();
    await _proofSubscription.cancel();
    await _proofTail;
    _pendingCapabilities.clear();
  }
}
