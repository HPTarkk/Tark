import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/settings/settings_keys.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/session_role_store.dart';
import '../../domain/service/transfer_mode_store.dart';

@LazySingleton(as: TransferModeStore)
class TransferModeStoreImpl implements TransferModeStore {
  TransferModeStoreImpl(this._prefs, this._roleStore);

  final SharedPreferences _prefs;
  final SessionRoleStore _roleStore;
  TransferMode _mode = TransferMode.wifi;
  final _modeController = StreamController<TransferMode>.broadcast();

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modeController.stream;

  @override
  Future<void> initialize() async {
    _mode = TransferMode.fromKey(_prefs.getString(SettingsKeys.transportMode));
  }

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    // A side taken on the hotspot bridge means nothing once the transport
    // changes — without this, switching back to plain Wi-Fi would keep
    // announcing "host" to a channel where nobody hosts.
    _roleStore.clear();
    await _prefs.setString(SettingsKeys.transportMode, mode.key);
    if (!_modeController.isClosed) _modeController.add(mode);
  }
}
