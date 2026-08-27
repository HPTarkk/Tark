/// Opaque proof bytes returned by a peer on a Ping/Pong route that the
/// transport has already matched by source route and challenge token.
final class TransportRouteProofObservation {
  const TransportRouteProofObservation({
    required this.peerKey,
    required this.token,
    required this.challengeEpoch,
    required this.encodedProof,
    required this.observedAt,
  });

  final String peerKey;
  final int token;
  final int challengeEpoch;
  final String encodedProof;
  final DateTime observedAt;
}
