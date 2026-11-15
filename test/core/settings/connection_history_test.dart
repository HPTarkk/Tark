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

  test('an explicit Wi-Fi preference prevents Bluetooth resume after a free repository fallback', () async {
    await history.remember('bluetooth', bluetoothEngine: 'classic');
    await prefs.setString(SettingsKeys.transportMode, 'bluetooth');
    await prefs.setString(SettingsKeys.transportPin, 'wifi');
    await prefs.setString(SettingsKeys.btLastRole, 'host');
    await prefs.setBool(SettingsKeys.autoReconnectEnabled, true);
    expect(history.shouldResumeClassicBluetooth(isAndroid: true), false);
    await prefs.setString(SettingsKeys.transportPin, 'bluetooth');
    expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);
  });

  group('cold-start resume stands down', () {
    setUp(() async {
      await history.remember('bluetooth', bluetoothEngine: 'classic');
      await prefs.setString(SettingsKeys.transportMode, 'bluetooth');
      await prefs.setString(SettingsKeys.btLastRole, 'host');
    });

    test('cancelling it once stops it on later cold starts', () async {
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);
      await history.standDownBluetoothResume();
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), false);
      // Connecting on purpose still resumes the remembered role.
      expect(history.canResumeClassicBluetooth, true);
    });

    test('one unanswered resume is ordinary, a second ends it', () async {
      await history.recordBluetoothResumeMiss();
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);
      await history.recordBluetoothResumeMiss();
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), false);
    });

    test('a real Bluetooth connection arms it again', () async {
      await history.standDownBluetoothResume();
      await history.rememberBluetoothEngine('classic');
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);

      await history.recordBluetoothResumeMiss();
      await history.remember('bluetooth');
      await history.recordBluetoothResumeMiss();
      expect(history.shouldResumeClassicBluetooth(isAndroid: true), true);
    });

    test('a Wi-Fi call does not arm a stood-down resume', () async {
      await history.standDownBluetoothResume();
      await history.remember('wifi');
      expect(history.bluetoothResumeStoodDown, true);
    });
  });
}
