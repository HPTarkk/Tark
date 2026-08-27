import 'dart:async';

import '../../../transfer/domain/entity/connection_health.dart';
import '../../../transfer/domain/entity/transfer_mode.dart';
import '../../../transfer/domain/repository/transfer_repository.dart';
import '../../../transfer/domain/service/hotspot_control.dart';
import '../../../transfer/domain/service/hotspot_link_keeper.dart';
import '../../../transfer/domain/service/transfer_mode_store.dart';
import '../entity/room.dart';
import 'room_failover_transport_orchestrator.dart';
import 'room_transport_planner.dart';

/// Production transport starter for a Room failover decision.
///
/// This adapter deliberately owns only the replacement transport edge. Room
/// identity, membership, election epoch and attachment generation stay in the
/// Room failover runtime. A local hotspot winner really starts Android's
/// LocalOnlyHotspot and adopts its fresh credentials. A remote hotspot winner
/// is *not* faked as connected: Android may rotate credentials, so this device
/// stays degraded until the existing recovery/invite flow provides a real
/// rejoin path.
///
/// [TransferRepository.connect] is already a broadcast live-session health
/// surface (including through LiveTransferRepository), so observing it here
/// does not create a second transport connection. The returned handle owns only
/// this starter's health subscription and, when this device created the
/// replacement hotspot, that hotspot reservation.
final class RoomLiveFailoverTransportStarter {
  RoomLiveFailoverTransportStarter({
    required this.localMemberId,
    required this.modeStore,
    required this.transfer,
    required this.hotspotHost,
    required this.hotspotLinkKeeper,
  });

  final RoomMemberId localMemberId;
  final TransferModeStore modeStore;
  final TransferRepository transfer;
  final HotspotHost hotspotHost;
  final HotspotLinkKeeper hotspotLinkKeeper;

  Future<RoomFailoverTransportHandle> call(
    RoomFailoverTransportContext context,
  ) async {
    final plan = context.attempt.decision.plan;
    var ownsHotspot = false;

    switch (plan.kind) {
      case RoomTransportKind.sharedLan:
        await modeStore.setMode(TransferMode.wifi);
      case RoomTransportKind.hotspot:
        final localIsHost = plan.hotspotHost == localMemberId;
        if (localIsHost) {
          final credentials = await hotspotHost.start();
          ownsHotspot = true;
          hotspotLinkKeeper.adopt(credentials);
        }
        await modeStore.setMode(TransferMode.hotspot);
        if (!localIsHost) {
          context.callbacks.degraded(
            reason: 'failover_waiting_for_remote_hotspot_rejoin',
          );
        }
      case RoomTransportKind.bluetooth:
        await modeStore.setMode(TransferMode.bluetooth);
      case RoomTransportKind.guest:
        await modeStore.setMode(TransferMode.guest);
      case null:
        return RoomFailoverTransportHandle(() async {});
    }

    final role = switch (plan.kind) {
      RoomTransportKind.hotspot when plan.hotspotHost == localMemberId =>
        'host',
      RoomTransportKind.hotspot => 'joiner',
      _ => 'peer',
    };

    late final StreamSubscription<ConnectionHealth> healthSubscription;
    healthSubscription = transfer.connect().listen(
      (health) {
        switch (health.status) {
          case ConnectionHealthStatus.healthy:
            context.callbacks.ready(role: role);
          case ConnectionHealthStatus.degraded ||
              ConnectionHealthStatus.reconnecting ||
              ConnectionHealthStatus.renegotiating:
            context.callbacks.degraded(reason: health.status.name);
          case ConnectionHealthStatus.down:
            context.callbacks.failed(reason: 'replacement_transport_down');
        }
      },
      onError: (Object _) {
        context.callbacks.failed(reason: 'replacement_transport_health_error');
      },
    );

    return RoomFailoverTransportHandle(() async {
      await healthSubscription.cancel();
      if (ownsHotspot) {
        await hotspotLinkKeeper.release();
        await hotspotHost.stop();
      }
    });
  }
}
