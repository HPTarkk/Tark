import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/settings/settings_keys.dart';
import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/transfer_mode_store.dart';

@LazySingleton(as: TransferModeStore)
class TransferModeStoreImpl implements TransferModeStore {
  TransferMode _mode = TransferMode.wifi;
  final _modeController = StreamController<TransferMode>.broadcast();

  @override
  TransferMode get mode => _mode;

  @override
  Stream<TransferMode> get modeChanges => _modeController.stream;

  @override
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = TransferMode.fromKey(prefs.getString(SettingsKeys.transportMode));
  }

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SettingsKeys.transportMode, mode.key);
    if (!_modeController.isClosed) _modeController.add(mode);
  }
}
