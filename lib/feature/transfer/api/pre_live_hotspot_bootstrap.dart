import 'dart:async';

import 'package:get_it/get_it.dart';

import '../../../core/utils/logger.dart';
import '../domain/entity/hotspot_credentials.dart';
import '../domain/entity/session_role.dart';
import '../domain/entity/wifi_hotspot_segment.dart';
import '../domain/service/hotspot_control.dart';
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
  PreLiveHotspotBootstrap({
    Future<HotspotCredentials?> Function()? starter,
    Future<HotspotJoinResult> Function(HotspotCredentials)? joiner,
    this.hostTimeout = defaultHostTimeout,
  }) : _starter = starter ?? _startWithTransferBridge,
       _joiner = joiner ?? _joinWithTransferBridge;

  final Future<HotspotCredentials?> Function() _starter;
  final Future<HotspotJoinResult> Function(HotspotCredentials) _joiner;

  /// How long [prepareHost] waits for the access point before giving up.
  ///
  /// Without a limit the Room sat on "Getting your phone ready…" for good
  /// when a step never answered, while the other phone waited at its camera
  /// for a code that was never coming. The bridge already limits each
  /// platform start; this is the backstop for everything around it, and is
  /// long enough to include a first-time permission prompt.
  final Duration hostTimeout;

  static const defaultHostTimeout = Duration(seconds: 45);

  /// The bridge a transfer-bridge start is using, so a timed-out start can
  /// tear it down instead of leaving an AP coming up behind a screen that has
  /// already said it failed.
  static WifiHotspotCubit? _startingBridge;

  /// The AP's credentials, or null when this phone could not raise one in
  /// [hostTimeout].
  // Re-typed through `then` first: a starter written as `() async => creds`
  // returns a Future<HotspotCredentials>, whose `timeout` cannot take a
  // null-returning fallback.
  Future<HotspotCredentials?> prepareHost() => _starter()
      .then<HotspotCredentials?>((credentials) => credentials)
      .timeout(
        hostTimeout,
        onTimeout: () {
          Logger.diagnostic(
            'room_transport: hotspot start timed out after '
            '${hostTimeout.inSeconds}s',
          );
          final bridge = _startingBridge;
          _startingBridge = null;
          if (bridge != null) unawaited(_abandonStart(bridge));
          return null;
        },
      );

  /// Joins [credentials] through the same bridge funnel the manual hotspot
  /// join has always used.
  ///
  /// Calling [HotspotJoiner.join] directly associated the phone and nothing
  /// else. The bridge's join also drops any access point this phone still
  /// holds (two live Wi-Fi networks make the native bind refuse to pick one),
  /// hands the link to [HotspotLinkKeeper] (which rebinds the sockets when
  /// Android moves the process and reports a lost AP), and starts the
  /// keep-alive (wake and Wi-Fi locks) so the joiner does not doze while the
  /// Room waits for its first proof. That is the path that connected phones
  /// reliably before the Room flow existed.
  Future<HotspotJoinResult> joinHost(HotspotCredentials credentials) =>
      _joiner(credentials);

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
    _startingBridge = bridge;
    try {
      bridge.switchSegment(WifiHotspotSegment.hotspot);
      await bridge.chooseRole(HotspotRole.host);
      // A timeout already gave up on this start and is tearing it down.
      if (!identical(_startingBridge, bridge)) return null;
      if (bridge.state.phase != HotspotPhase.ready) return null;
      final credentials = bridge.state.credentials;
      if (credentials == null) return null;

      // The credential is the hand-off boundary.  `WifiHotspotCubit.close()`
      // only releases bridge UI subscriptions, but an Android EventChannel
      // cancellation may stall on physical devices.  Do not make the Room's
      // authenticated Bluetooth credential publication wait behind that
      // non-essential cleanup; the HotspotLinkKeeper already owns the AP.
      unawaited(_releaseBridgeAfterHandoff(bridge));
      return credentials;
    } finally {
      if (identical(_startingBridge, bridge)) _startingBridge = null;
      // Cleanup is deliberately detached immediately above once credentials
      // are ready. Failure paths still release the short-lived bridge.
      if (bridge.state.credentials == null && !bridge.isClosed) {
        await bridge.close();
      }
    }
  }

  /// Stops a start that ran out of time: cancels the bridge's retries, asks
  /// the platform to drop the AP request (which also answers the start still
  /// waiting on its callback) and releases the bridge. An AP that made it up
  /// just too late was handed to the link keeper, so the keeper lets go of it
  /// too; a start only gets this far when the keeper held no live AP before.
  static Future<void> _abandonStart(WifiHotspotCubit bridge) async {
    try {
      if (!bridge.isClosed) {
        await bridge.backToRoleChoice().timeout(const Duration(seconds: 3));
      }
      final getIt = GetIt.instance;
      if (getIt.isRegistered<HotspotLinkKeeper>()) {
        await getIt<HotspotLinkKeeper>().release();
      }
    } catch (_) {
      Logger.diagnostic('room_transport: abandoning the hotspot start failed');
    }
    await _releaseBridgeAfterHandoff(bridge);
  }

  static Future<HotspotJoinResult> _joinWithTransferBridge(
    HotspotCredentials credentials,
  ) async {
    final getIt = GetIt.instance;
    if (!getIt.isRegistered<WifiHotspotCubit>()) {
      return getIt<HotspotJoiner>().join(credentials);
    }
    final bridge = getIt<WifiHotspotCubit>();
    try {
      bridge.switchSegment(WifiHotspotSegment.hotspot);
      if (bridge.state.role != HotspotRole.join) {
        await bridge.chooseRole(HotspotRole.join);
      }
      await bridge.joinNetwork(credentials);
      return switch (bridge.state.joinPhase) {
        JoinPhase.joined => HotspotJoinResult.joined,
        JoinPhase.wifiOff => HotspotJoinResult.wifiOff,
        JoinPhase.locationOff => HotspotJoinResult.locationOff,
        _ => HotspotJoinResult.declined,
      };
    } finally {
      // As for the host: the link keeper and keep-alive now own the link, so
      // the short-lived bridge is released without holding up the Room.
      unawaited(_releaseBridgeAfterHandoff(bridge));
    }
  }

  static Future<void> _releaseBridgeAfterHandoff(
    WifiHotspotCubit bridge,
  ) async {
    try {
      await bridge.close().timeout(const Duration(seconds: 2));
      Logger.diagnostic('room_transport: hotspot bridge cleanup complete');
    } on TimeoutException {
      Logger.diagnostic('room_transport: hotspot bridge cleanup timed out');
    } catch (_) {
      Logger.diagnostic('room_transport: hotspot bridge cleanup failed');
    }
  }
}
