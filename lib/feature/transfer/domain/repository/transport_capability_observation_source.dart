import '../entity/transport_capability_observation.dart';

/// Optional live-transport surface for verified peer capability evidence.
///
/// This stays separate from [TransferRepository] / Wi-Fi's base contract so
/// transports and test doubles that do not support capability evidence are not
/// forced to fabricate it. Room composition may consume this interface only
/// when the active transport actually implements it.
abstract interface class TransportCapabilityObservationSource {
  /// Low-frequency, privacy-safe evidence from a bidirectionally verified peer.
  ///
  /// [TransportCapabilityObservation.peerKey] is still transport-scoped and
  /// must be bound to an already-admitted durable RoomMemberId before planner
  /// or failover logic may use the capability.
  Stream<TransportCapabilityObservation> get transportCapabilityObservations;
}
