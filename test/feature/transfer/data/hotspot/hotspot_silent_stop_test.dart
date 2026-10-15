import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/data/hotspot/wifi_hotspot_controller.dart';

/// 2026-10-15: a Galaxy S8 hosting while still on the house Wi-Fi lost its
/// access point about forty seconds in, and Android never said so. The phone
/// went on believing it was hosting; nothing moved or recovered again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tark/hotspot');
  const events = 'tark/hotspot/events';

  const home = 'wlan0/192.168.8.155';
  const ap = 'swlan0/192.168.43.1';

  late Set<String> addresses;

  /// Looks that come back without the access point, whatever is up.
  var blinks = 0;

  setUp(() {
    addresses = {home};
    blinks = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'start') {
        // The access point's address appears once it is up.
        addresses = {...addresses, ap};
        return {'ssid': 'DIRECT-ab', 'passphrase': 'pass1234'};
      }
      return null;
    });
    // The native stream never reports anything: the silent case.
    messenger.setMockStreamHandler(
      const EventChannel(events),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(const EventChannel(events), null);
  });

  WifiHotspotController controller() => WifiHotspotController(
    localAddresses: () async {
      if (blinks > 0) {
        blinks--;
        return {home};
      }
      return addresses;
    },
    apWatchInterval: const Duration(milliseconds: 10),
    apDiscoveryWindow: const Duration(milliseconds: 200),
    supported: true,
  );

  Future<void> waitFor(bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('an access point whose address vanishes is reported stopped', () async {
    final hotspot = controller();
    var stopped = 0;
    final sub = hotspot.onStopped.listen((_) => stopped++);
    await hotspot.start();
    expect(hotspot.isHosting, isTrue);

    // Let it learn its own address, then take the access point off the air
    // while the house Wi-Fi stays.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(hotspot.isHosting, isTrue, reason: 'still up, nothing said');
    addresses = {home};
    await waitFor(() => stopped > 0);

    expect(stopped, 1);
    expect(hotspot.isHosting, isFalse);
    await sub.cancel();
  });

  test('one missed look is not a stop', () async {
    final hotspot = controller();
    var stopped = 0;
    final sub = hotspot.onStopped.listen((_) => stopped++);
    await hotspot.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // A single look without it.
    blinks = 1;
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(stopped, 0);
    expect(hotspot.isHosting, isTrue);
    await hotspot.stop();
    await sub.cancel();
  });

  test('our own stop is never reported as the OS stopping it', () async {
    final hotspot = controller();
    var stopped = 0;
    final sub = hotspot.onStopped.listen((_) => stopped++);
    await hotspot.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await hotspot.stop();
    addresses = {home};
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(stopped, 0);
    await sub.cancel();
  });

  test('an address that never shows up is not taken as a stop', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return {'ssid': 'DIRECT-ab', 'passphrase': 'pass1234'};
          }
          return null;
        });
    final hotspot = controller();
    var stopped = 0;
    final sub = hotspot.onStopped.listen((_) => stopped++);
    await hotspot.start();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(stopped, 0);
    expect(hotspot.isHosting, isTrue);
    await hotspot.stop();
    await sub.cancel();
  });
}
