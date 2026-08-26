import 'dart:async';

import '../../../transfer/domain/entity/transport_capability_observation.dart';
import '../../../transfer/domain/repository/transport_capability_observation_source.dart';
import 'room_capability_failover_runtime.dart';

/// Session-scoped bridge from transport-verified capability observations into
/// the durable Room failover runtime.
///
/// The transport source is deliberately not trusted to name a Room member.
/// [RoomCapabilityFailoverRuntime.observePeer] admits an observation only when
/// its opaque [TransportCapabilityObservation.peerKey] is already bound to an
/// active, canonical RoomMemberId for the current attachment generation.
/// Replacement attachments clear those bindings, so a delayed observation from
/// an old route fails closed instead of becoming election evidence.
final class RoomTransportCapabilityObservationBridge {
  RoomTransportCapabilityObservationBridge({
    required this.runtime,
    required TransportCapabilityObservationSource source,
  }) {
    _subscription = source.transportCapabilityObservations.listen(
      _observe,
      // Capability evidence is optional. A transport observation stream error
      // must not tear down the logical Room or manufacture fallback evidence.
      onError: (_) {},
    );
  }

  final RoomCapabilityFailoverRuntime runtime;
  late final StreamSubscription<TransportCapabilityObservation> _subscription;
  bool _disposed = false;

  void _observe(TransportCapabilityObservation observation) {
    if (_disposed) return;
    final capability = observation.capability;
    runtime.observePeer(
      peerKey: observation.peerKey,
      canHostHotspot: capability.canHostHotspot,
      bluetoothSupported: capability.bluetoothSupported,
      backgroundReady: capability.backgroundReady,
      batteryPercent: capability.batteryPercent,
      at: observation.observedAt,
      prefersHotspotHost: capability.prefersHotspotHost,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
  }
}
