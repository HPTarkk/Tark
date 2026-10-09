import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/logger.dart';
import 'app_settings.dart';
import 'settings_keys.dart';

/// Evidence of an established link, separate from the user's transport choice.
/// A settings change or a failed attempt must never manufacture resume history.
class ConnectionHistory {
  const ConnectionHistory(this.prefs);
  final SharedPreferences prefs;

  static ConnectionHistory? get registered =>
      GetIt.instance.isRegistered<SharedPreferences>()
      ? ConnectionHistory(GetIt.instance<SharedPreferences>())
      : null;

  bool get canResumeClassicBluetooth =>
      prefs.getString(SettingsKeys.lastConnectedTransport) == 'bluetooth' &&
      prefs.getString(SettingsKeys.btLastConnectedEngine) == 'classic';

  /// One cold-start policy shared by the router and Home's rejoin prompt.
  bool shouldResumeClassicBluetooth({required bool isAndroid}) {
    if (!isAndroid || !canResumeClassicBluetooth) return false;
    if (!(prefs.getBool(SettingsKeys.autoReconnectEnabled) ??
        AppSettings.defaults().autoReconnectEnabled)) {
      return false;
    }
    if (prefs.getString(SettingsKeys.transportMode) != 'bluetooth') {
      return false;
    }
    final preference = prefs.getString(SettingsKeys.transportPin);
    if (preference != null &&
        preference != 'auto' &&
        preference != 'bluetooth') {
      return false;
    }
    return switch (prefs.getString(SettingsKeys.btLastRole)) {
      'host' => true,
      'joiner' =>
        prefs.getString(SettingsKeys.btLastPeerId)?.trim().isNotEmpty ?? false,
      _ => false,
    };
  }

  Future<void> rememberBluetoothEngine(String engine) async {
    try {
      await prefs.setString(SettingsKeys.btLastConnectedEngine, engine);
    } catch (_) {
      Logger.diagnostic('connection history: engine could not be saved');
    }
  }

  Future<void> remember(String transport, {String? bluetoothEngine}) async {
    // Update before awaiting persistence so an older Bluetooth bootstrap
    // cannot overwrite a newer Wi-Fi connection later.
    final writes = <Future<bool>>[
      prefs.setString(SettingsKeys.lastConnectedTransport, transport),
      if (bluetoothEngine != null)
        prefs.setString(SettingsKeys.btLastConnectedEngine, bluetoothEngine),
    ];
    try {
      await Future.wait(writes);
    } catch (_) {
      Logger.diagnostic('connection history: transport could not be saved');
    }
  }
}
