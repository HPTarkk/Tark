/// Opaque proof bytes returned by a peer on a Ping/Pong route that the
/// transport has already matched by source route and challenge token.
final class TransportRouteProofObservation {
  const TransportRouteProofObservation({
    required this.peerKey,
    required this.token,
    required this.challengeEpoch,
    required this.encodedProof,
    required this.observedAt,
    this.transportSenderId,
  });

  /// Carrier-observed route used by the proof authority. This is the identity
  /// binding input; it is never derived from display metadata.
  final String peerKey;
  final int token;
  final int challengeEpoch;
  final String encodedProof;
  final DateTime observedAt;

  /// Ephemeral sender id carried by the exact matched Pong that returned this
  /// proof, when the transport has one.
  ///
  /// This is presence metadata, not Room identity or authorization. Callers may
  /// use it only after [peerKey]'s proof has verified, for example to project
  /// that proven member's volatile talking state onto the durable Room row.
  /// Older transports/tests may omit it and therefore fail closed for that
  /// projection without losing Room connectivity.
  final String? transportSenderId;
}
