import 'package:equatable/equatable.dart';

/// An encoded carrier-handover announcement seen on the wire, still unopened.
///
/// The transport deliberately does not interpret it. A handover says "leave
/// this network and join that one", which is authority over the entire Room's
/// connectivity, and the only thing entitled to grant that is a signature
/// chaining to the Room's issuer key — which lives in the Room layer, not
/// here. So this carries the bytes and the route they arrived by, and stops.
final class CarrierHandoverObservation extends Equatable {
  const CarrierHandoverObservation({
    required this.peerKey,
    required this.encodedHandover,
    required this.observedAt,
  });

  /// The transport-scoped route this arrived on. Not identity, and not used as
  /// any part of the decision — kept for diagnostics and so a caller can tell
  /// two announcements arriving by different paths apart.
  final String peerKey;

  final String encodedHandover;
  final DateTime observedAt;

  @override
  List<Object?> get props => [peerKey, encodedHandover, observedAt];
}
