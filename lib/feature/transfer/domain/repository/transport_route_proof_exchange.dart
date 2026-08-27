import '../entity/transport_route_proof_observation.dart';

typedef TransportRouteProofProvider =
    Future<String?> Function({required int token, required int challengeEpoch});

abstract interface class TransportRouteProofExchange {
  Stream<TransportRouteProofObservation> get routeProofObservations;

  void setRouteProofProvider(TransportRouteProofProvider? provider);
}
