import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source assertions, not behaviour: `WifiJoinHandler` is Kotlin talking to
/// ConnectivityManager, and this repo has no instrumented Android harness to
/// run it against. Worth keeping only for the invariants that are easy to
/// delete by accident and expensive to notice — every one of them below was
/// either the cause of a silent join failure or the fix for it.
void main() {
  final source = File(
    'android/app/src/main/kotlin/com/b1101/tark/hotspot/WifiJoinHandler.kt',
  ).readAsStringSync();

  /// The same file with comments removed. The negative assertions below have
  /// to run against this: those invariants are worth explaining in the source,
  /// and prose naming a deleted method would otherwise read as the method
  /// still being there.
  final code = source
      .split('\n')
      .where((line) {
        final trimmed = line.trimLeft();
        return !trimmed.startsWith('//') &&
            !trimmed.startsWith('*') &&
            !trimmed.startsWith('/*');
      })
      .join('\n');

  test('wifi join binds only the network it can identify', () {
    expect(source, contains('WifiInfo'));
    expect(source, contains('findExpectedWifiNetwork'));
    expect(source, contains('transportInfo as? WifiInfo'));
    expect(source, contains('Build.VERSION.SDK_INT < Build.VERSION_CODES.Q'));
    expect(source, contains('exact.size > 1'));
    expect(source, contains('networkMatchesJoinedAp(network)'));
    expect(source, contains('if (want == null)'));
    // Picking the first Wi-Fi handle that turns up is how the process used to
    // end up pinned to our own AP instead of the host's.
    expect(code, isNot(contains('allNetworks.firstOrNull')));
    // Its replacement answered "true" whenever the SSID was unreadable, which
    // is the pre-Q norm — so it re-pinned to whatever was there.
    expect(code, isNot(contains('looksLikeOurAp()')));
  });

  test('wifi join can still identify a network below API 29', () {
    // capabilityWifiSsid() is null on every candidate below Q and the system
    // SSID is redacted without location permission, so the station address is
    // the only identity left. Without it the handler cannot bind at all on
    // Android 9 while our own hotspot is still up — which reads on the phone
    // as "joined" with a channel that is silent both ways.
    expect(source, contains('stationIpv4()'));
    expect(source, contains('stationWifiNetwork(candidates)'));
    expect(source, contains('getLinkProperties(network)'));
    // Two handles is the ordinary shape of "joined an AP while ours was still
    // up". It must narrow the choice, never refuse outright.
    expect(code, isNot(contains('if (candidates.size != 1)')));
  });

  test('below API 29 the binding decisions fall open', () {
    // #71's strictness is built on NetworkCapabilities.transportInfo, which is
    // API 29+. Applying it below that is not caution but permanent refusal:
    // there is no per-Network SSID to check against, and the keeper callback
    // that carries a joiner back onto the AP arrives before DHCP has given the
    // station an address to match. An Android 9 joiner then sits unpinned with
    // no route back, while the same phone hosts perfectly — a host runs no
    // keeper. Anything that makes these three answers unconditional again is
    // re-introducing that.
    expect(source, contains('canIdentifyNetworks'));
    expect(source, contains('fallbackWifiNetwork(candidates)'));
    expect(source, contains('return !canIdentifyNetworks'));
  });
}
