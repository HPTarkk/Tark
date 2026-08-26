import '../entity/transport_capability_advertisement.dart';
import '../entity/transport_capability_observation.dart';
import 'transfer_repository.dart';

/// The Wi-Fi/UDP transport specifically — as opposed to [TransferRepository],
/// which DI resolves to whichever transport the current mode selects.
/// Consumers that must talk to the Wi-Fi transport regardless of mode (the
/// hotspot bridge waiting for the first packet from the joined peer) depend
/// on this instead of the concrete implementation.
abstract interface class WifiTransferRepository implements TransferRepository {
  /// Latest locally-proven transport capability snapshot, or null when the
  /// platform evidence is unavailable/unknown. Never fabricate eligibility.
  TransportCapabilityAdvertisement? get localTransportCapability;

  /// Privacy-safe capability evidence decoded from live peer heartbeats.
  /// Consumers must bind [TransportCapabilityObservation.peerKey] to an
  /// already-admitted durable RoomMemberId before using it for Room planning.
  Stream<TransportCapabilityObservation> get transportCapabilityObservations;

  /// Rebuilds both UDP sockets on the network this device is on NOW, without
  /// ending the session.
  ///
  /// A socket keeps the network it was created on. When the OS moves the phone
  /// between networks mid-call — a joiner dropped off an internet-less hotspot
  /// and put back on it, which is what a screen-off cycle does — the sockets
  /// survive, look healthy, and send into a route that no longer exists.
  ///
  /// Deliberately NOT [stopConnection]: that advances the generation counter
  /// and so ends the listening stream the live session is subscribed to,
  /// permanently. This rebinds underneath the same stream.
  void rebindSockets();
}
