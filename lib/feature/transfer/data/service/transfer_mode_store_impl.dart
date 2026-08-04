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
  final _modeController = StreamController<TransferMode>.broadcast();

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modeController.stream;

  @override
  Future<void> initialize() async {
    _mode = TransferMode.fromKey(_prefs.getString(SettingsKeys.transportMode));
    // A trial that lapsed (or a refund) while a paid transport was selected
    // would otherwise strand the user on a screen they can no longer use —
    // and, worse, keep the DI selector handing out the Wi-Fi repository.
    // Fall back to the free transport and persist it, so the demotion is
    // decided exactly once rather than re-evaluated on every read.
    if (_mode.requiresPremium &&
        !_gate.allows(PremiumFeature.wifiTransport)) {
      Logger.log('TransferMode: ${_mode.key} not entitled, falling back to BT');
      _mode = TransferMode.bluetooth;
      await _prefs.setString(SettingsKeys.transportMode, _mode.key);
    }
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
}
