import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/settings/connection_history.dart';
import 'package:tark/core/settings/settings_keys.dart';

void main() {
  late SharedPreferences prefs;
  late ConnectionHistory history;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    history = ConnectionHistory(prefs);
  });

  test('a Bluetooth bootstrap alone cannot manufacture call history', () async {
    await history.rememberBluetoothEngine('classic');
    expect(history.canResumeClassicBluetooth, false);
    await history.remember('bluetooth');
    expect(history.canResumeClassicBluetooth, true);
  });

  test(
    'a later Wi-Fi call stays authoritative after manual Bluetooth selection',
    () async {
      await history.remember('bluetooth', bluetoothEngine: 'classic');
      await history.remember('hotspot');
      await prefs.setString(SettingsKeys.transportMode, 'bluetooth');
      expect(history.canResumeClassicBluetooth, false);
    },
  );

  test('late engine metadata cannot overwrite a newer connection', () async {
    await history.remember('wifi');
    await history.rememberBluetoothEngine('classic');
    expect(prefs.getString(SettingsKeys.lastConnectedTransport), 'wifi');
    expect(history.canResumeClassicBluetooth, false);
  });

  test('BLE history does not authorize Classic redial', () async {
    await history.remember('bluetooth', bluetoothEngine: 'ble');
    expect(history.canResumeClassicBluetooth, false);
  });

  test(
    'an explicit Wi-Fi preference prevents Bluetooth resume after a free repository fallback',
    () async {
      await history.remember('bluetooth', bluetoothEngine: 'classic');
      await prefs.setString(SettingsKeys.transportMode, 'bluetooth');
      await prefs.setString(SettingsKeys.transportPin, 'wifi');
      await prefs.setString(SettingsKeys.btLastRole, 'host');
      await prefs.setBool(SettingsKeys.autoReconnectEnabled, true);
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), false);
      await prefs.setString(SettingsKeys.transportPin, 'bluetooth');
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);
    },
  );
}
