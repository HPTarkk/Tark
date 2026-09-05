import 'package:get_it/get_it.dart';

import '../domain/entity/hotspot_credentials.dart';
import '../domain/entity/session_role.dart';
import '../domain/entity/wifi_hotspot_segment.dart';
import '../domain/service/hotspot_link_keeper.dart';
import '../domain/service/session_role_store.dart';
import '../presentation/manager/wifi_hotspot_cubit.dart';

/// Prepares Tark's temporary hotspot for a Room invite without exposing the
/// host/join bridge UI to the user.
///
/// This is deliberately a transfer-feature API rather than Room code reaching
/// into [WifiHotspotCubit]. The existing bridge already owns Android
/// permissions, bounded hotspot retries, side exclusivity, keep-alive, carrier
/// recording and [HotspotLinkKeeper] adoption. Reusing that funnel keeps the
/// Quick Share-style Room flow from growing a second, subtly different hotspot
/// state machine.
///
/// The bootstrap is allowed only when the session-scoped role hint says this
/// phone is the creator/host side. Durable Room invite authority is never read
/// here and therefore cannot make two authorised members both create an AP.
class PreLiveHotspotBootstrap {
  PreLiveHotspotBootstrap({Future<HotspotCredentials?> Function()? starter})
    : _starter = starter ?? _startWithTransferBridge;

  final Future<HotspotCredentials?> Function() _starter;

  Future<HotspotCredentials?> prepareHost() => _starter();

  static Future<HotspotCredentials?> _startWithTransferBridge() async {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<SessionRoleStore>() ||
        !getIt.isRegistered<HotspotLinkKeeper>() ||
        !getIt.isRegistered<WifiHotspotCubit>()) {
      return null;
    }

    final roleStore = getIt<SessionRoleStore>();
    if (roleStore.role != SessionRole.host) return null;

    final keeper = getIt<HotspotLinkKeeper>();
    final existing = keeper.credentials;
    if (keeper.state == HotspotLinkState.up && existing != null) {
      return existing;
    }

    final bridge = getIt<WifiHotspotCubit>();
    try {
      bridge.switchSegment(WifiHotspotSegment.hotspot);
      await bridge.chooseRole(HotspotRole.host);
      if (bridge.state.phase != HotspotPhase.ready) return null;
      return bridge.state.credentials;
    } finally {
      // WifiHotspotCubit.close intentionally keeps an established AP, selected
      // network and foreground keep-alive alive. It only releases the bridge
      // screen's subscriptions/retry machinery, handing the attachment to the
      // HotspotLinkKeeper that outlives this hidden bootstrap.
      await bridge.close();
    }
  }
}
