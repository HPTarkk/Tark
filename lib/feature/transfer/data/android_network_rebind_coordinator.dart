import 'dart:async';

import '../../../core/utils/logger.dart';
import '../domain/entity/session_role.dart';
import '../domain/entity/transfer_mode.dart';
import '../domain/service/session_role_store.dart';
import '../domain/service/transfer_mode_store.dart';
import 'android_network_binding.dart';

abstract interface class AndroidNetworkBindingPort {
  Future<AndroidNetworkSelection?> current();
  Stream<AndroidNetworkSelection> get changes;
  Future<bool> bind(AndroidNetworkSelection selection);
  Future<void> clear();
}

final class PlatformAndroidNetworkBindingPort
    implements AndroidNetworkBindingPort {
  const PlatformAndroidNetworkBindingPort();

  @override
  Future<AndroidNetworkSelection?> current() => AndroidNetworkBinding.current();

  @override
  Stream<AndroidNetworkSelection> get changes => AndroidNetworkBinding.changes;

  @override
  Future<bool> bind(AndroidNetworkSelection selection) =>
      AndroidNetworkBinding.bind(selection);

  @override
  Future<void> clear() => AndroidNetworkBinding.clear();
}

/// Keeps both UDP sockets aligned with Android's selected local Wi-Fi Network.
///
/// Process binding only affects sockets opened afterwards. When the selected
/// Network generation changes this coordinator first asks native Android to pin
/// the exact observed generation, then rebuilds both Wi-Fi UDP sockets under
/// the same logical session. Bluetooth/Guest clear process binding so an old
/// local Wi-Fi decision cannot hijack their traffic.
///
/// Hosting is the case this must keep its hands off. A LocalOnlyHotspot is not
/// a Network Android will ever "select": on a host that is also a client of an
/// ordinary router — the common case, since hosting does not cost you your
/// internet — the selected local Wi-Fi is the *router*, and pinning the process
/// to it routes every packet away from the AP subnet the peers are actually on.
/// The host's own binding is cleared by `HotspotJoiner.leave()` when it takes
/// that side; all this has to do is not put one back.
final class AndroidNetworkRebindCoordinator {
  AndroidNetworkRebindCoordinator(
    this._rebindWifiSockets,
    this._modes,
    this._roles, {
    AndroidNetworkBindingPort port = const PlatformAndroidNetworkBindingPort(),
    Map<String, DateTime> Function()? peersHeardAt,
    Future<String?> Function()? stationAddress,
    DateTime Function()? clock,
    this.bridgeTick = const Duration(seconds: 1),
  }) : _port = port,
       _peersHeardAt = peersHeardAt,
       _stationAddress = stationAddress,
       _clock = clock ?? DateTime.now;

  final void Function() _rebindWifiSockets;
  final TransferModeStore _modes;
  final SessionRoleStore _roles;
  final AndroidNetworkBindingPort _port;

  /// When each peer address was last heard, from the Wi-Fi transport.
  final Map<String, DateTime> Function()? _peersHeardAt;

  /// This phone's address as a client of the router, if it is one.
  final Future<String?> Function()? _stationAddress;
  final DateTime Function() _clock;

  /// How often a host checks which side of it the other phones are on.
  final Duration bridgeTick;

  /// How recently a peer must have been heard to count as being there.
  static const peerFresh = Duration(seconds: 3);

  Timer? _bridgeTimer;
  bool _bridging = false;
  bool _bridgeBusy = false;

  StreamSubscription<AndroidNetworkSelection>? _networkSub;
  StreamSubscription<TransferMode>? _modeSub;
  StreamSubscription<SessionRole?>? _roleSub;
  int _modeGeneration = 0;
  int _roleGeneration = 0;
  int? _boundNetworkGeneration;
  bool _active = false;
  bool _disposed = false;
  bool _loggedHostSkip = false;

  Future<void> start() async {
    if (_disposed || _networkSub != null) return;
    _networkSub = _port.changes.listen(_onNetworkChanged);
    _modeSub = _modes.modeChanges.listen(_onModeChanged);
    final roles = _roles;
    if (roles is SessionRoleChangeSource) {
      final changes = (roles as SessionRoleChangeSource).roleChanges;
      _roleSub = changes.listen(_onRoleChanged);
    }
    await _applyMode(_modes.mode);
  }

  void _onModeChanged(TransferMode mode) {
    unawaited(_applyMode(mode));
  }

  void _onRoleChanged(SessionRole? _) {
    // Android can report a selected local Wi-Fi Network before the one-scan
    // bootstrap has committed this device's temporary session role. If that
    // first callback arrived while we still looked like the host, it was
    // correctly ignored — but there may be no second platform callback after
    // the role becomes joiner. Re-read the current selection now so a settled
    // role cannot strand otherwise-successful Wi-Fi joins on the wrong process
    // network.
    final roleGeneration = ++_roleGeneration;
    unawaited(_reconcileRole(roleGeneration));
  }

  Future<void> _reconcileRole(int roleGeneration) async {
    if (_disposed || !_active || roleGeneration != _roleGeneration) return;
    final modeGeneration = _modeGeneration;
    if (!_hosting) _stopBridge();
    if (_hosting) {
      await _clearForHost(
        roleGeneration: roleGeneration,
        modeGeneration: modeGeneration,
      );
      return;
    }

    final selection = await _port.current();
    if (_disposed ||
        !_active ||
        modeGeneration != _modeGeneration ||
        roleGeneration != _roleGeneration ||
        _hosting) {
      return;
    }
    if (!_eligible(selection)) return;
    if (_boundNetworkGeneration == selection!.generation) return;
    await _adoptNetwork(selection, modeGeneration);
  }

  /// Clears a client-side process pin while this device is the hotspot host.
  ///
  /// `clear()` crosses an asynchronous platform boundary. The role may switch
  /// back to joiner before it returns; if so, the just-completed old clear can
  /// have landed *after* a newer joiner bind. Forget the optimistic generation
  /// and reconcile the latest role so the stale side effect cannot win merely
  /// because Android emitted no second network callback.
  Future<void> _clearForHost({
    required int roleGeneration,
    required int modeGeneration,
  }) async {
    _boundNetworkGeneration = null;
    _loggedHostSkip = false;
    await _port.clear();
    // Sockets keep the network they were made on. Made while the process was
    // pinned to the router, they stay on it after the pin goes, and a phone
    // joining this one's access point is never heard: the move off the router
    // timed out on the host with the other phone sitting on its hotspot
    // (2026-10-16 13:06 and 13:18). Rebuilt here, they listen on every
    // interface, the access point's included.
    if (!_disposed && _active && roleGeneration == _roleGeneration) {
      _bridging = false;
      _rebindWifiSockets();
      Logger.diagnostic(
        'network: hosting — released the router pin and rebuilt both UDP '
        'sockets',
      );
      _startBridge();
    }
    if (!_disposed &&
        _active &&
        roleGeneration != _roleGeneration &&
        modeGeneration == _modeGeneration) {
      _boundNetworkGeneration = null;
      unawaited(_reconcileRole(_roleGeneration));
    }
  }

  Future<void> _applyMode(TransferMode mode) async {
    final generation = ++_modeGeneration;
    final wantsLocalWifi =
        mode == TransferMode.wifi || mode == TransferMode.hotspot;
    _active = wantsLocalWifi;
    _boundNetworkGeneration = null;

    if (!wantsLocalWifi) {
      _stopBridge();
      await _port.clear();
      return;
    }
    if (_hosting) {
      _startBridge();
      return;
    }

    final selection = await _port.current();
    if (_disposed || generation != _modeGeneration || !_active) return;
    if (!_eligible(selection)) return;
    final bound = await _port.bind(selection!);
    if (_disposed || generation != _modeGeneration || !_active) return;
    // `start()` can be awaiting the native bind while one-scan bootstrap
    // settles this device onto the host side. Never let that older joiner bind
    // complete after the host's role change and pin host traffic to its normal
    // router. Use the same stale-clear reconciliation as role-driven clears so
    // a subsequent host -> joiner flip remains safe too.
    if (_hosting) {
      if (bound) {
        await _clearForHost(
          roleGeneration: _roleGeneration,
          modeGeneration: generation,
        );
      }
      return;
    }
    if (bound) {
      _boundNetworkGeneration = selection.generation;
      Logger.diagnostic(
        'network: selected local Wi-Fi bound generation=${selection.generation}',
      );
    }
  }

  void _onNetworkChanged(AndroidNetworkSelection selection) {
    if (_disposed || !_active || !_eligible(selection)) return;
    if (_hosting) {
      // Nothing to adopt and nothing to remember: our peers are on an AP the
      // framework never selects, and holding the generation would make the
      // first change after we stop hosting look like one we had handled.
      _boundNetworkGeneration = null;
      if (!_loggedHostSkip) {
        _loggedHostSkip = true;
        Logger.diagnostic(
          'network: hosting — leaving the process unpinned rather than '
          'following the selected local Wi-Fi off our own AP',
        );
      }
      return;
    }
    _loggedHostSkip = false;
    if (_boundNetworkGeneration == selection.generation) return;
    final modeGeneration = _modeGeneration;
    unawaited(_adoptNetwork(selection, modeGeneration));
  }

  bool get _hosting => _roles.role == SessionRole.host;

  /// Whether a host should pin itself to the router it is also a client of:
  /// the other phones are heard there, recently, and none on its own access
  /// point.
  ///
  /// One process binding cannot serve both sides. Unpinned, a host hears
  /// everyone but its packets to the router's subnet leave by the default
  /// network, which on these phones is not the router: the phone still on
  /// the router never heard the host announce its hotspot, so the move it
  /// was waiting for never came (2026-10-16 18:23, 18:25, 18:29). Pinned, it
  /// reaches the router and loses its access point. So it follows the other
  /// phone: pinned while that phone is on the router, unpinned once it has
  /// gone quiet there — which is what joining the hotspot looks like from
  /// here — and pinned again if it comes back.
  static bool hostNeedsRouter({
    required Map<String, DateTime> heard,
    required String? station,
    required DateTime now,
  }) {
    final router = _subnetOf(station);
    if (router == null) return false;
    var onRouter = false;
    for (final MapEntry(key: address, value: at) in heard.entries) {
      if (now.difference(at) > peerFresh) continue;
      final subnet = _subnetOf(address);
      if (subnet == null) continue;
      if (subnet != router) return false;
      onRouter = true;
    }
    return onRouter;
  }

  static String? _subnetOf(String? address) {
    if (address == null) return null;
    final parts = address.split('.');
    if (parts.length != 4) return null;
    return parts.take(3).join('.');
  }

  void _startBridge() {
    if (_peersHeardAt == null || _stationAddress == null) return;
    _bridgeTimer ??= Timer.periodic(bridgeTick, (_) => unawaited(_bridge()));
  }

  void _stopBridge() {
    _bridgeTimer?.cancel();
    _bridgeTimer = null;
    _bridging = false;
  }

  Future<void> _bridge() async {
    if (_bridgeBusy) return;
    if (_disposed || !_active || !_hosting) {
      _stopBridge();
      return;
    }
    _bridgeBusy = true;
    try {
      final roleGeneration = _roleGeneration;
      final modeGeneration = _modeGeneration;
      final want = hostNeedsRouter(
        heard: _peersHeardAt!(),
        station: await _stationAddress!(),
        now: _clock(),
      );
      if (_disposed ||
          !_active ||
          !_hosting ||
          roleGeneration != _roleGeneration ||
          modeGeneration != _modeGeneration ||
          want == _bridging) {
        return;
      }
      if (want) {
        final selection = await _port.current();
        if (!_eligible(selection) || !_hosting || _disposed) return;
        if (!await _port.bind(selection!)) return;
        if (!_hosting || _disposed || roleGeneration != _roleGeneration) {
          await _port.clear();
          return;
        }
        _bridging = true;
        _rebindWifiSockets();
        Logger.diagnostic(
          'network: hosting, the other phone is on the router — pinned to it '
          'so it can hear this one',
        );
      } else {
        await _port.clear();
        if (_disposed || roleGeneration != _roleGeneration) return;
        _bridging = false;
        _rebindWifiSockets();
        Logger.diagnostic(
          'network: hosting, the other phone left the router — unpinned for '
          'the access point',
        );
      }
    } finally {
      _bridgeBusy = false;
    }
  }

  Future<void> _adoptNetwork(
    AndroidNetworkSelection selection,
    int modeGeneration,
  ) async {
    if (_hosting) return;
    final bound = await _port.bind(selection);
    if (_disposed || !_active || modeGeneration != _modeGeneration) return;
    // The user can take the host side while the bind is in flight. Undo it
    // rather than leave the host pinned to a router its peers are not on.
    if (_hosting) {
      _boundNetworkGeneration = null;
      if (bound) {
        await _clearForHost(
          roleGeneration: _roleGeneration,
          modeGeneration: modeGeneration,
        );
      }
      return;
    }
    if (!bound) {
      Logger.diagnostic(
        'network: rejected stale/unavailable local Wi-Fi generation=${selection.generation}',
      );
      return;
    }
    if (_boundNetworkGeneration == selection.generation) return;
    _boundNetworkGeneration = selection.generation;
    _rebindWifiSockets();
    Logger.diagnostic(
      'network: local Wi-Fi generation=${selection.generation}; rebuilt both UDP sockets',
    );
  }

  bool _eligible(AndroidNetworkSelection? selection) =>
      selection != null &&
      selection.available &&
      selection.isWifi &&
      !selection.isVpn &&
      selection.networkHandle != null &&
      selection.interfaceName != null;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopBridge();
    _modeGeneration++;
    _roleGeneration++;
    await _networkSub?.cancel();
    await _modeSub?.cancel();
    await _roleSub?.cancel();
    _networkSub = null;
    _modeSub = null;
    _roleSub = null;
    await _port.clear();
  }
}
