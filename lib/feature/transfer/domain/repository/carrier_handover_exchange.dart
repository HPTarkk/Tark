import '../entity/carrier_handover_observation.dart';

/// Reads what the elected host is announcing, so the transport can attach it.
///
/// Synchronous and cheap on purpose: it is consulted on every outgoing ping
/// and pong, and it returns null for all but the few seconds a promotion is
/// actually in flight.
typedef CarrierHandoverProvider = String? Function();

/// Optional live-transport surface for moving a whole Room onto a new network.
///
/// Kept out of the base [TransferRepository] contract for the same reason
/// capability evidence is: Bluetooth, the guest link and every test double
/// would otherwise have to fabricate an implementation of something they
/// cannot do. Room composition consumes it only when the active transport
/// really implements it.
abstract interface class CarrierHandoverExchange {
  /// Installs what to attach to outgoing control packets. Null clears it.
  void setCarrierHandoverProvider(CarrierHandoverProvider? provider);

  /// Announcements seen on the wire, unverified and uninterpreted.
  Stream<CarrierHandoverObservation> get carrierHandoverObservations;
}
