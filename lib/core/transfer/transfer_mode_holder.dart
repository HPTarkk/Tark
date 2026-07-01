import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../feature/transfer/domain/entity/transfer_mode.dart';

/// Holds the user's chosen transport (WiFi vs Bluetooth), persisted across
/// app launches. Mirrors [LocaleService]'s static-service shape so it's
/// ready before [runApp] and can be read synchronously by the DI factory
/// that selects which [TransferRepository] implementation to inject.
class TransferModeHolder {
  static final _mode = ValueNotifier<TransferMode>(TransferMode.wifi);

  static ValueListenable<TransferMode> get listenable => _mode;
  static TransferMode get mode => _mode.value;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _mode.value = TransferMode.fromKey(prefs.getString('transport_mode'));
  }

  static Future<void> setMode(TransferMode mode) async {
    _mode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('transport_mode', mode.key);
  }
}
