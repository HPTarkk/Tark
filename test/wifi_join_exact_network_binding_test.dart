import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wifi join uses exact network binding guards', () {
    final source = File(
      'android/app/src/main/kotlin/com/b1101/tark/hotspot/WifiJoinHandler.kt',
    ).readAsStringSync();

    expect(source, contains('WifiInfo'));
    expect(source, contains('findExpectedWifiNetwork'));
    expect(source, contains('transportInfo as? WifiInfo'));
    expect(source, contains('Build.VERSION.SDK_INT < Build.VERSION_CODES.Q'));
    expect(source, contains('exact.size > 1'));
    expect(source, contains('candidates.size != 1'));
    expect(source, contains('networkMatchesJoinedAp(network)'));
    expect(source, contains('if (want == null)'));
    expect(source, isNot(contains('allNetworks.firstOrNull')));
    expect(source, isNot(contains('looksLikeOurAp()')));
  });
}
