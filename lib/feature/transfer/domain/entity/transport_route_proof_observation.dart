/// Opaque proof bytes returned by a peer on a Ping/Pong route that the
/// transport has already matched by source route and challenge token.
///
/// The transfer layer deliberately does not parse the proof or name a Room
/// member. Room composition verifies the encoded proof cryptographically before
/// the carrier route can become durable-member authority.
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

  /// Session epoch carried by the Ping that created this challenge. This is the
  /// challenger's epoch, not the responder's Pong epoch.
  final int challengeEpoch;
  final String encodedProof;
  final DateTime observedAt;
}
