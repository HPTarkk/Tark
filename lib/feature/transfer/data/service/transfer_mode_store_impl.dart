import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/settings/settings_keys.dart';
import '../../../../core/utils/logger.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/session_role_store.dart';
import '../../domain/service/transfer_mode_store.dart';

@LazySingleton(as: TransferModeStore)
class TransferModeStoreImpl implements TransferModeStore {
  TransferModeStoreImpl(this._prefs, this._roleStore, this._gate);

  final SharedPreferences _prefs;
  final SessionRoleStore _roleStore;
  final LicenseGate _gate;
  TransferMode _mode = TransferMode.wifi;
  TransferMode? _pinned;
  final _modeController = StreamController<TransferMode>.broadcast();
  final _pinController = StreamController<TransferMode?>.broadcast();

  /// Stored value meaning "no pin". Written out rather than clearing the key,
  /// so that going back to automatic is distinguishable from never having
  /// opened Advanced settings — they behave identically today, and a stored
  /// answer is the one that survives a future change of default.
  static const _autoKey = 'auto';

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modeController.stream;

  @override
  TransferMode? get pinnedMode => _pinned;

  @override
  Stream<TransferMode?> get pinChanges => _pinController.stream;

  @override
  Future<void> initialize() async {
    _mode = TransferMode.fromKey(_prefs.getString(SettingsKeys.transportMode));
    _pinned = _readPin();
    // A trial that lapsed (or a refund) while a paid transport was selected
    // would otherwise strand the user on a screen they can no longer use —
    // and, worse, keep the DI selector handing out the Wi-Fi repository.
    // Fall back to the free transport and persist it, so the demotion is
    // decided exactly once rather than re-evaluated on every read.
    if (_mode.requiresPremium && !_gate.allows(PremiumFeature.wifiTransport)) {
      Logger.log('TransferMode: ${_mode.key} not entitled, falling back to BT');
      _mode = TransferMode.bluetooth;
      await _prefs.setString(SettingsKeys.transportMode, _mode.key);
    }
    // The pin is demoted separately, and to automatic rather than to
    // Bluetooth. Leaving a paid pin in place would have the advisor keep
    // short-circuiting to a transport [setMode] then refuses, which reads on
    // screen as a button that does nothing; and rewriting it to Bluetooth
    // would put a hand-picked value in a slot the user never touched, so that
    // a later purchase restores nothing.
    final pinned = _pinned;
    if (pinned != null &&
        pinned.requiresPremium &&
        !_gate.allows(PremiumFeature.wifiTransport)) {
      Logger.log('TransferMode: pin ${pinned.key} not entitled, back to auto');
      _pinned = null;
      await _prefs.setString(SettingsKeys.transportPin, _autoKey);
    }
  }

  /// `fromKey` cannot be used here: it answers an absent/unknown key with
  /// [TransferMode.wifi], which is the right default for "which transport" and
  /// exactly the wrong one for "did the user pin a transport" — every install
  /// that has never opened Advanced settings would come back pinned to Wi-Fi.
  TransferMode? _readPin() {
    final raw = _prefs.getString(SettingsKeys.transportPin);
    if (raw == null || raw == _autoKey) return null;
    return TransferMode.values.where((m) => m.key == raw).firstOrNull;
  }

  @override
  Future<void> setMode(TransferMode mode) async {
    // Backstop, not the user-facing check: every picker consults the gate
    // first so it can show a lock and open the paywall. Reaching here
    // unentitled means a path skipped that, and silently doing nothing beats
    // selecting a transport whose screens will not work.
    if (mode.requiresPremium && !_gate.allows(PremiumFeature.wifiTransport)) {
      Logger.log('TransferMode: ${mode.key} blocked, no entitlement');
      return;
    }
    _mode = mode;
    // A side taken on the hotspot bridge means nothing once the transport
    // changes — without this, switching back to plain Wi-Fi would keep
    // announcing "host" to a channel where nobody hosts.
    _roleStore.clear();
    await _prefs.setString(SettingsKeys.transportMode, mode.key);
    if (!_modeController.isClosed) _modeController.add(mode);
  }

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {
    if (mode != null &&
        mode.requiresPremium &&
        !_gate.allows(PremiumFeature.wifiTransport)) {
      Logger.log('TransferMode: pin ${mode.key} blocked, no entitlement');
      return;
    }
    _pinned = mode;
    await _prefs.setString(SettingsKeys.transportPin, mode?.key ?? _autoKey);
    if (!_pinController.isClosed) _pinController.add(mode);
    // Pinning is also a switch. Un-pinning is not — see [setPinnedMode] on the
    // interface for why the effective mode is left where it is.
    if (mode != null) await setMode(mode);
  }
}
