import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/hotspot/wifi_hotspot_controller.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('tark/wifi_join');
  const creds = HotspotCredentials(
    ssid: 'test-network',
    passphrase: 'test-password',
  );

  late AndroidWifiJoiner joiner;
  late Completer<bool?> nativeJoin;
  var joinCalls = 0;
  var leaveCalls = 0;

  setUp(() {
    joiner = AndroidWifiJoiner();
    nativeJoin = Completer<bool?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'join':
              joinCalls++;
              return nativeJoin.future;
            case 'leave':
              leaveCalls++;
              return null;
          }
          return null;
        });
  });

  tearDown(() async {
    // Clear the process-wide lease before the next test while the fake channel
    // is still installed. Production uses the same explicit leave boundary.
    await joiner.leave();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('same credentials coalesce while joining and stay stable once joined', () async {
    final first = joiner.join(creds);
    await Future<void>.delayed(Duration.zero);
    final duplicate = joiner.join(creds);
    await Future<void>.delayed(Duration.zero);

    expect(joinCalls, 1);

    nativeJoin.complete(true);
    expect(await first, HotspotJoinResult.joined);
    expect(await duplicate, HotspotJoinResult.joined);

    // Rebuilding the setup page must not replace an already-bound native
    // network just because it submits the same invite again.
    expect(await AndroidWifiJoiner().join(creds), HotspotJoinResult.joined);
    expect(joinCalls, 1);
  });

  test('explicit leave lets the same credentials perform a real retry', () async {
    nativeJoin.complete(true);
    expect(await joiner.join(creds), HotspotJoinResult.joined);
    expect(joinCalls, 1);

    await joiner.leave();
    expect(leaveCalls, 1);

    // A deliberate teardown/loss boundary clears the stable lease. The same
    // invite is allowed to reach native code again instead of being suppressed
    // forever as an already-connected duplicate.
    nativeJoin = Completer<bool?>()..complete(true);
    expect(await joiner.join(creds), HotspotJoinResult.joined);
    expect(joinCalls, 2);
  });
}
