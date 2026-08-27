import '../entity/transport_route_proof_observation.dart';

typedef TransportRouteProofProvider =
    Future<String?> Function({required int token, required int challengeEpoch});

/// Optional live-transport surface for challenge-bound proof carriage.
///
/// The transport owns only route/token correlation and opaque bytes. It never
/// interprets the proof as Room identity. Room composition installs a provider
/// for the local member and verifies [routeProofObservations] before binding a
/// carrier route to durable membership.
abstract interface class TransportRouteProofExchange {
  Stream<TransportRouteProofObservation> get routeProofObservations;

  void setRouteProofProvider(TransportRouteProofProvider? provider);
}
