import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/session_keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tark/keepalive');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    SessionKeepAlive.debugIsAndroid = true;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    SessionKeepAlive.debugIsAndroid = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'QR host uses connected-device keepalive before microphone starts',
    () async {
      const adapter = SessionKeepAliveWakeLock();
      await adapter.start(usesMicrophone: false);
      await adapter.start();
      await adapter.stop();
      expect(calls.map((call) => call.method), ['start', 'start', 'stop']);
      expect(calls[0].arguments, {'usesMicrophone': false});
      expect(calls[1].arguments, {'usesMicrophone': true});
      expect(calls[2].arguments, isNull);
    },
  );

  test(
    'unsupported platforms never request foreground services or settings',
    () async {
      SessionKeepAlive.debugIsAndroid = false;
      await SessionKeepAlive.start();
      await SessionKeepAlive.stop();
      await SessionKeepAlive.requestIgnoreBatteryOptimizations();
      await SessionKeepAlive.openAutoStartSettings();
      expect(await SessionKeepAlive.isIgnoringBatteryOptimizations(), isTrue);
      expect(await SessionKeepAlive.isMiui(), isFalse);
      expect(calls, isEmpty);
    },
  );

  test('battery and ROM evidence reflect explicit native replies', () async {
    var ignoring = false;
    var miui = true;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'isIgnoringBatteryOptimizations' => ignoring,
        'isMiui' => miui,
        _ => null,
      },
    );
    expect(await SessionKeepAlive.isIgnoringBatteryOptimizations(), isFalse);
    expect(await SessionKeepAlive.isMiui(), isTrue);
    ignoring = true;
    miui = false;
    expect(await SessionKeepAlive.isIgnoringBatteryOptimizations(), isTrue);
    expect(await SessionKeepAlive.isMiui(), isFalse);
  });

  test('settings methods use the correct native affordances', () async {
    await SessionKeepAlive.requestIgnoreBatteryOptimizations();
    await SessionKeepAlive.openAutoStartSettings();
    expect(calls.map((call) => call.method), [
      'requestIgnoreBatteryOptimizations',
      'openAutoStartSettings',
    ]);
  });

  for (final missing in [false, true]) {
    test(
      '${missing ? 'missing plugin' : 'native failure'} cannot crash session teardown',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (missing) throw MissingPluginException();
          throw PlatformException(code: 'lock_unavailable');
        });
        await SessionKeepAlive.start(usesMicrophone: false);
        await SessionKeepAlive.stop();
        await SessionKeepAlive.requestIgnoreBatteryOptimizations();
        await SessionKeepAlive.openAutoStartSettings();
        expect(await SessionKeepAlive.isIgnoringBatteryOptimizations(), isTrue);
        expect(await SessionKeepAlive.isMiui(), isFalse);
        expect(calls.length, 6);
      },
    );
  }

  test(
    'absent optimization and ROM answers preserve conservative defaults',
    () async {
      expect(await SessionKeepAlive.isIgnoringBatteryOptimizations(), isTrue);
      expect(await SessionKeepAlive.isMiui(), isFalse);
    },
  );
}
