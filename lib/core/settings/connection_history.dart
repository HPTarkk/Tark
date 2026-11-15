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

  /// The Bluetooth resume screen has been on screen in this run of the app.
  /// It is the "get back to them?" question for a Bluetooth call, so Home
  /// must not ask the same thing again underneath it.
  static bool resumeShownThisRun = false;

  bool get canResumeClassicBluetooth =>
      prefs.getString(SettingsKeys.lastConnectedTransport) == 'bluetooth' &&
      prefs.getString(SettingsKeys.btLastConnectedEngine) == 'classic';

  /// Unanswered cold-start resumes in a row before they stop on their own.
  /// One miss is ordinary (the other phone was not open yet); a second says
  /// the call is over, and asking again on every launch is only noise.
  static const resumeMissLimit = 2;

  /// Whether the hands-free cold-start resume has been called off: the user
  /// cancelled it, or it went unanswered [resumeMissLimit] times running. It
  /// stays off until Bluetooth really connects again, which is the only new
  /// evidence that there is a call to resume. Connecting on purpose, from a
  /// room or the Bluetooth screen, is never affected.
  bool get bluetoothResumeStoodDown =>
      prefs.getBool(SettingsKeys.btResumeStoodDown) ?? false;

  /// One cold-start policy shared by the router and Home's rejoin prompt.
  bool shouldResumeClassicBluetooth({required bool isAndroid}) {
    if (!isAndroid || !canResumeClassicBluetooth) return false;
    if (bluetoothResumeStoodDown) return false;
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

  /// The user cancelled a resume: do not open it again by itself.
  Future<void> standDownBluetoothResume() async {
    try {
      await prefs.setBool(SettingsKeys.btResumeStoodDown, true);
    } catch (_) {
      Logger.diagnostic('connection history: resume stand-down not saved');
    }
  }

  /// A resume ran its full course and nobody answered.
  Future<void> recordBluetoothResumeMiss() async {
    final misses = (prefs.getInt(SettingsKeys.btResumeMisses) ?? 0) + 1;
    try {
      await prefs.setInt(SettingsKeys.btResumeMisses, misses);
      if (misses >= resumeMissLimit) {
        await prefs.setBool(SettingsKeys.btResumeStoodDown, true);
      }
    } catch (_) {
      Logger.diagnostic('connection history: resume miss not saved');
    }
  }

  /// Bluetooth connected: there is a live call to resume again.
  Future<void> _rearmBluetoothResume() async {
    if (!prefs.containsKey(SettingsKeys.btResumeStoodDown) &&
        !prefs.containsKey(SettingsKeys.btResumeMisses)) {
      return;
    }
    await Future.wait([
      prefs.remove(SettingsKeys.btResumeStoodDown),
      prefs.remove(SettingsKeys.btResumeMisses),
    ]);
  }

  Future<void> rememberBluetoothEngine(String engine) async {
    try {
      // Called when a peer connects over Bluetooth, on either engine.
      await _rearmBluetoothResume();
      await prefs.setString(SettingsKeys.btLastConnectedEngine, engine);
    } catch (_) {
      Logger.diagnostic('connection history: engine could not be saved');
    }
  }

  Future<void> remember(String transport, {String? bluetoothEngine}) async {
    // Update before awaiting persistence so an older Bluetooth bootstrap
    // cannot overwrite a newer Wi-Fi connection later.
    final writes = <Future<void>>[
      prefs.setString(SettingsKeys.lastConnectedTransport, transport),
      if (bluetoothEngine != null)
        prefs.setString(SettingsKeys.btLastConnectedEngine, bluetoothEngine),
      if (transport == 'bluetooth') _rearmBluetoothResume(),
    ];
    try {
      await Future.wait(writes);
    } catch (_) {
      Logger.diagnostic('connection history: transport could not be saved');
    }
  }
}
