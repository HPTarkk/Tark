import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native binding preserves WifiJoinHandler process pin first', () async {
    final source = await File(
      'android/app/src/main/kotlin/com/b1101/tark/network/NetworkBindingHandler.kt',
    ).readAsString();

    final bound = source.indexOf('connectivity.boundNetworkForProcess');
    final active = source.indexOf('connectivity.activeNetwork');
    final arbitraryWifi = source.indexOf(
      'connectivity.allNetworks.firstOrNull(::isLocalWifi)',
    );

    expect(bound, greaterThanOrEqualTo(0));
    expect(active, greaterThan(bound));
    expect(arbitraryWifi, greaterThan(active));
    expect(
      source,
      contains('if (isLocalWifi(bound)) return bound'),
      reason:
          'The exact app-scoped hotspot network selected by WifiJoinHandler '
          'must win over the internet/default Wi-Fi network.',
    );
  });
}
