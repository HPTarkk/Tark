import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entity/transfer_mode.dart';
import '../../domain/service/transfer_mode_store.dart';

@LazySingleton(as: TransferModeStore)
class TransferModeStoreImpl implements TransferModeStore {
  TransferMode _mode = TransferMode.wifi;

  @override
  TransferMode get mode => _mode;

  @override
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = TransferMode.fromKey(prefs.getString('transport_mode'));
  }

  @override
  Future<void> setMode(TransferMode mode) async {
    _mode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('transport_mode', mode.key);
  }
}
