import 'dart:async';

import '../../../transfer/api/transfer_api.dart';
import '../entity/transport_attachment.dart';
import 'room_session_runtime.dart';

/// Translates a concrete transport's low-frequency health stream into the
/// logical [RoomSessionRuntime] lifecycle without making Room state depend on
/// Wi-Fi/hotspot/Bluetooth/WebRTC implementation details.
///
/// Each binding is attachment-generation scoped. Replacing a transport disposes
/// the old subscription through [RoomSessionRuntime.resources], and delayed
/// health from an older generation is ignored rather than resurrecting it.
class RoomTransportHealthRuntimeAdapter {
  RoomTransportHealthRuntimeAdapter(this.runtime);

  final RoomSessionRuntime runtime;

  Future<int> attach({
    required TransportKind kind,
    required Stream<ConnectionHealth> health,
    String? role,
    String? reason,
  }) async {
    final generation = await runtime.attach(
      kind: kind,
      role: role,
      reason: reason,
    );
    await _bind(generation, health);
    return generation;
  }

  Future<int> replace({
    required TransportKind kind,
    required Stream<ConnectionHealth> health,
    String? role,
    String? reason,
  }) async {
    final generation = await runtime.replaceTransport(
      kind: kind,
      role: role,
      reason: reason,
    );
    await _bind(generation, health);
    return generation;
  }

  Future<void> _bind(int generation, Stream<ConnectionHealth> health) async {
    late final StreamSubscription<ConnectionHealth> subscription;
    subscription = health.listen(
      (value) => _onHealth(generation, value),
      onError: (Object _) =>
          _failIfCurrent(generation, reason: 'transport_health_stream_error'),
      onDone: () =>
          _failIfCurrent(generation, reason: 'transport_health_stream_closed'),
    );

    final owned = runtime.ownCurrentAttachmentResource(
      generation,
      'transport_health_subscription',
      subscription.cancel,
    );
    if (!owned) await subscription.cancel();
  }

  void _onHealth(int generation, ConnectionHealth health) {
    if (!_isCurrent(generation)) return;
    switch (health.status) {
      case ConnectionHealthStatus.healthy:
        runtime.ready(generation: generation);
      case ConnectionHealthStatus.degraded:
        runtime.degraded(generation: generation, reason: 'transport_degraded');
      case ConnectionHealthStatus.reconnecting:
        runtime.recover(
          generation: generation,
          reason: 'transport_reconnecting',
        );
      case ConnectionHealthStatus.renegotiating:
        runtime.recover(
          generation: generation,
          reason: 'transport_renegotiating',
        );
      case ConnectionHealthStatus.down:
        runtime.failed(generation: generation, reason: 'transport_down');
    }
  }

  void _failIfCurrent(int generation, {required String reason}) {
    if (!_isCurrent(generation)) return;
    runtime.failed(generation: generation, reason: reason);
  }

  bool _isCurrent(int generation) =>
      !runtime.hasLeft && generation == runtime.attachmentGeneration;
}
