import 'package:equatable/equatable.dart';

/// Bounded, non-secret transport capability evidence advertised by a live peer.
///
/// This is capability/readiness evidence only. It is never Room identity,
/// membership authorization, or proof that a peer may host a transport. Room
/// orchestration must attribute it to an already-admitted durable member before
/// using it for planning/election.
final class TransportCapabilityAdvertisement extends Equatable {
  const TransportCapabilityAdvertisement({
    required this.canHostHotspot,
    required this.bluetoothSupported,
    required this.backgroundReady,
    required this.batteryPercent,
    this.prefersHotspotHost = false,
    this.hostingAccessPoint = false,
    this.gaveUpMove = false,
  }) : assert(batteryPercent >= 0 && batteryPercent <= 100);

  final bool canHostHotspot;
  final bool bluetoothSupported;
  final bool backgroundReady;
  final int batteryPercent;
  final bool prefersHotspotHost;

  /// This phone is holding an access point up right now.
  final bool hostingAccessPoint;

  /// This phone has just given up on a move to a hotspot.
  final bool gaveUpMove;

  @override
  List<Object?> get props => [
    canHostHotspot,
    bluetoothSupported,
    backgroundReady,
    batteryPercent,
    prefersHotspotHost,
    hostingAccessPoint,
    gaveUpMove,
  ];
}
