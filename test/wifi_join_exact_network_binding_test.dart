import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hotspot join binds only an unambiguous matching Wi-Fi Network', () {
    final source = File(
      'android/app/src/main/kotlin/com/b1101/tark/hotspot/WifiJoinHandler.kt',
    ).readAsStringSync();

    expect(source, contains('import android.net.wifi.WifiInfo'));
    expect(source, contains('private fun findExpectedWifiNetwork'));
    expect(source, contains('(caps.transportInfo as? WifiInfo)?.ssid'));
    expect(source, contains('exact.size > 1'));
    expect(source, contains('candidates.size != 1'));
    expect(source, contains('networkMatchesJoinedAp(network)'));
    expect(
      source,
      isNot(contains('connectivity.allNetworks.firstOrNull')),
      reason: 'Never bind an arbitrary first Wi-Fi Network handle.',
    );
    expect(
      source,
      isNot(contains('private fun looksLikeOurAp()')),
      reason: 'Keeper validation must inspect the callback Network itself.',
    );
  });
}
