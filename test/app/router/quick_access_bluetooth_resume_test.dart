import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/router/quick_access.dart';
import 'package:tark/core/config/onboarding_config.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';

void main() {
  Future<SharedPreferences> prefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues({
      OnboardingPrefs.completed: true,
      ...values,
    });
    return SharedPreferences.getInstance();
  }

  const lastBluetoothHost = {
    SettingsKeys.transportMode: 'bluetooth',
    SettingsKeys.btLastRole: 'host',
  };

  test('a last Bluetooth call as host opens the resume screen', () async {
    final p = await prefs(lastBluetoothHost);
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: true),
      AppRoutes.bluetoothResumePath,
    );
  });

  test('a joiner resumes only when it remembers who it dialed', () async {
    final withPeer = await prefs({
      SettingsKeys.transportMode: 'bluetooth',
      SettingsKeys.btLastRole: 'joiner',
      SettingsKeys.btLastPeerId: 'AA:BB:CC:DD:EE:FF',
    });
    expect(QuickAccess.shouldResumeBluetooth(withPeer, isAndroid: true), true);

    final withoutPeer = await prefs({
      SettingsKeys.transportMode: 'bluetooth',
      SettingsKeys.btLastRole: 'joiner',
    });
    expect(
      QuickAccess.shouldResumeBluetooth(withoutPeer, isAndroid: true),
      false,
    );
  });

  test('a later non-Bluetooth call means Landing', () async {
    final p = await prefs({
      ...lastBluetoothHost,
      SettingsKeys.transportMode: 'hotspot',
    });
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: true),
      AppRoutes.landingPath,
    );
  });

  test('Bluetooth chosen but never connected means Landing', () async {
    final p = await prefs({SettingsKeys.transportMode: 'bluetooth'});
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: true),
      AppRoutes.landingPath,
    );
  });

  test('the Auto-reconnect switch turns it off', () async {
    final p = await prefs({
      ...lastBluetoothHost,
      SettingsKeys.autoReconnectEnabled: false,
    });
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: true),
      AppRoutes.landingPath,
    );
  });

  test('not on Android means Landing', () async {
    final p = await prefs(lastBluetoothHost);
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: false),
      AppRoutes.landingPath,
    );
  });

  test('first run still goes to onboarding', () async {
    SharedPreferences.setMockInitialValues({...lastBluetoothHost});
    final p = await SharedPreferences.getInstance();
    expect(
      QuickAccess.resolveStartLocation(p, isAndroid: true),
      AppRoutes.onboardingPath,
    );
  });
}
