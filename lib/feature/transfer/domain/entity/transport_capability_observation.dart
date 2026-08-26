import 'transport_capability_advertisement.dart';

/// One privacy-safe capability observation from a live transport peer.
///
/// [peerKey] is an opaque transport/session identity only. Room code must bind
/// it to an already-admitted durable RoomMemberId before using [capability] for
/// transport planning or failover.
final class TransportCapabilityObservation {
  const TransportCapabilityObservation({
    required this.peerKey,
    required this.capability,
    required this.observedAt,
  });

  final String peerKey;
  final TransportCapabilityAdvertisement capability;
  final DateTime observedAt;
}
