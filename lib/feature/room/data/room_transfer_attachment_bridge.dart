import 'dart:async';

import '../../transfer/api/transfer_api.dart';
import '../domain/entity/transport_attachment.dart';
import '../domain/service/room_session_runtime.dart';

/// Small port that keeps the Room feature independent from concrete Wi-Fi,
/// Bluetooth and WebRTC implementations while still adapting the production
/// [TransferRepository] lifecycle.
abstract interface class RoomTransportAttachmentPort {
  Stream<ConnectionHealth> connect();

  void stopConnection();
}

/// Production adapter over the transport contract already used by the app.
final class TransferRepositoryRoomTransportPort
    implements RoomTransportAttachmentPort {
  const TransferRepositoryRoomTransportPort(this.repository);

  final TransferRepository repository;

  @override
  Stream<ConnectionHealth> connect() => repository.connect();

  @override
  void stopConnection() => repository.stopConnection();
}

/// Binds one concrete transport lifecycle to a logical [RoomSessionRuntime].
///
/// The Room survives degraded/reconnecting/down states. Replacing an
/// attachment advances the generation and disposes only the old transport's
/// subscription/stop handle. Explicit Room leave remains the only terminal
/// operation and disposes the current attachment through the runtime owner.
///
/// Stale callbacks are generation-gated before they can mutate Room state, so
/// a delayed event from an old Wi-Fi/hotspot/Bluetooth/WebRTC attachment cannot
/// resurrect itself after a replacement wins.
final class RoomTransferAttachmentBridge {
  RoomTransferAttachmentBridge({
    required this.runtime,
    required this.transport,
  });

  final RoomSessionRuntime runtime;
  final RoomTransportAttachmentPort transport;

  Future<int> attach({
    required TransportKind kind,
    String? role,
    String? reason,
  }) async {
    final generation = await runtime.attach(
      kind: kind,
      role: role,
      reason: reason,
    );
    await _bind(generation);
    return generation;
  }

  Future<int> replace({
    required TransportKind kind,
    String? role,
    String? reason,
  }) async {
    final generation = await runtime.replaceTransport(
      kind: kind,
      role: role,
      reason: reason,
    );
    await _bind(generation);
    return generation;
  }

  Future<void> _bind(int generation) async {
    if (runtime.hasLeft || generation != runtime.attachmentGeneration) return;

    final stopOwned = runtime.ownCurrentAttachmentResource(
      generation,
      'transport_stop',
      transport.stopConnection,
    );
    if (!stopOwned) {
      transport.stopConnection();
      return;
    }

    late final StreamSubscription<ConnectionHealth> subscription;
    try {
      subscription = transport.connect().listen(
        (health) => _onHealth(generation, health),
        onError: (_) {
          if (_accepts(generation)) {
            runtime.failed(
              generation: generation,
              reason: 'transport_health_stream_error',
            );
          }
        },
      );
    } catch (_) {
      if (_accepts(generation)) {
        runtime.failed(
          generation: generation,
          reason: 'transport_connect_failed',
        );
      }
      return;
    }

    final subscriptionOwned = runtime.ownCurrentAttachmentResource(
      generation,
      'transport_health_subscription',
      subscription.cancel,
    );
    if (!subscriptionOwned) await subscription.cancel();
  }

  bool _accepts(int generation) =>
      !runtime.hasLeft && generation == runtime.attachmentGeneration;

  void _onHealth(int generation, ConnectionHealth health) {
    if (!_accepts(generation)) return;

    switch (health.status) {
      case ConnectionHealthStatus.healthy:
        runtime.ready(generation: generation);
      case ConnectionHealthStatus.degraded:
        runtime.degraded(
          generation: generation,
          reason: 'transport_degraded',
        );
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
}
