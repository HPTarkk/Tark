import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/media_control.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tark/media_control');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    MediaControl.debugIsAndroid = true;
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    MediaControl.debugIsAndroid = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'notification access and other playback preserve confirmed native evidence',
    () async {
      var access = true;
      var playing = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'hasNotificationAccess' => access,
          'isOtherMediaPlaying' => playing,
          _ => null,
        };
      });
      expect(await MediaControl.hasAccess(), isTrue);
      expect(await MediaControl.isOtherMediaPlaying(), isTrue);
      access = false;
      playing = false;
      expect(await MediaControl.hasAccess(), isFalse);
      expect(await MediaControl.isOtherMediaPlaying(), isFalse);
      expect(calls.map((call) => call.method), [
        'hasNotificationAccess',
        'isOtherMediaPlaying',
        'hasNotificationAccess',
        'isOtherMediaPlaying',
      ]);
    },
  );

  test(
    'unknown native answers do not invent media access or playback',
    () async {
      expect(await MediaControl.hasAccess(), isFalse);
      expect(await MediaControl.isOtherMediaPlaying(), isFalse);
    },
  );

  test(
    'non-Android platform does not probe notification access or playback',
    () async {
      MediaControl.debugIsAndroid = false;
      expect(await MediaControl.hasAccess(), isFalse);
      expect(await MediaControl.isOtherMediaPlaying(), isFalse);
      expect(calls, isEmpty);
    },
  );

  test(
    'stop-casting affordance pauses other media through native channel',
    () async {
      await MediaControl.requestAccess();
      await MediaControl.pauseOtherMedia();
      expect(calls.map((call) => call.method), [
        'requestNotificationAccess',
        'pauseOtherMedia',
      ]);
      expect(calls.every((call) => call.arguments == null), isTrue);
    },
  );

  for (final missing in [false, true]) {
    test(
      '${missing ? 'missing plugin' : 'denied native calls'} remain best effort',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (missing) throw MissingPluginException();
          throw PlatformException(code: 'access_denied');
        });
        expect(await MediaControl.hasAccess(), isFalse);
        expect(await MediaControl.isOtherMediaPlaying(), isFalse);
        await MediaControl.requestAccess();
        await MediaControl.pauseOtherMedia();
        expect(calls.length, 4);
      },
    );
  }
}
