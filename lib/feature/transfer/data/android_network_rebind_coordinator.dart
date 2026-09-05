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
  }) : _port = port;

  final void Function() _rebindWifiSockets;
  final TransferModeStore _modes;
  final SessionRoleStore _roles;
  final AndroidNetworkBindingPort _port;

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
      await _port.clear();
      return;
    }
    if (_hosting) return;

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
