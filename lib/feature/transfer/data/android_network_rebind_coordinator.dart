import 'dart:async';

import '../../../core/utils/logger.dart';
import '../domain/entity/transfer_mode.dart';
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
final class AndroidNetworkRebindCoordinator {
  AndroidNetworkRebindCoordinator(
    this._rebindWifiSockets,
    this._modes, {
    AndroidNetworkBindingPort port = const PlatformAndroidNetworkBindingPort(),
  }) : _port = port;

  final void Function() _rebindWifiSockets;
  final TransferModeStore _modes;
  final AndroidNetworkBindingPort _port;

  StreamSubscription<AndroidNetworkSelection>? _networkSub;
  StreamSubscription<TransferMode>? _modeSub;
  int _modeGeneration = 0;
  int? _boundNetworkGeneration;
  bool _active = false;
  bool _disposed = false;

  Future<void> start() async {
    if (_disposed || _networkSub != null) return;
    _networkSub = _port.changes.listen(_onNetworkChanged);
    _modeSub = _modes.modeChanges.listen(_onModeChanged);
    await _applyMode(_modes.mode);
  }

  void _onModeChanged(TransferMode mode) {
    unawaited(_applyMode(mode));
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

    final selection = await _port.current();
    if (_disposed || generation != _modeGeneration || !_active) return;
    if (!_eligible(selection)) return;
    final bound = await _port.bind(selection!);
    if (_disposed || generation != _modeGeneration || !_active) return;
    if (bound) {
      _boundNetworkGeneration = selection.generation;
      Logger.diagnostic(
        'network: selected local Wi-Fi bound generation=${selection.generation}',
      );
    }
  }

  void _onNetworkChanged(AndroidNetworkSelection selection) {
    if (_disposed || !_active || !_eligible(selection)) return;
    if (_boundNetworkGeneration == selection.generation) return;
    final modeGeneration = _modeGeneration;
    unawaited(_adoptNetwork(selection, modeGeneration));
  }

  Future<void> _adoptNetwork(
    AndroidNetworkSelection selection,
    int modeGeneration,
  ) async {
    final bound = await _port.bind(selection);
    if (_disposed || !_active || modeGeneration != _modeGeneration) return;
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
    await _networkSub?.cancel();
    await _modeSub?.cancel();
    _networkSub = null;
    _modeSub = null;
    await _port.clear();
  }
}
