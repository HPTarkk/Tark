import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/voice_audio_session.dart';
import 'package:tark/feature/audio/domain/entity/audio_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tark/audio_session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// The native side never replies — what a wedged main thread looks like.
  void neverReply() => messenger.setMockMethodCallHandler(
    channel,
    (_) => Completer<Object?>().future,
  );

  test('reconfigure gives up once the routing limit passes', () {
    fakeAsync((async) {
      neverReply();
      var done = false;
      VoiceAudioSession.reconfigure().then((_) => done = true);

      async.elapse(
        VoiceAudioSession.routingLimit - const Duration(milliseconds: 1),
      );
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 2));
      expect(done, isTrue);
    });
  });

  test('configure gives up once the routing limit passes', () {
    fakeAsync((async) {
      neverReply();
      var done = false;
      VoiceAudioSession.configure().then((_) => done = true);
      async.elapse(VoiceAudioSession.routingLimit);
      expect(done, isTrue);
    });
  });

  test('quick calls give up after the short limit', () {
    fakeAsync((async) {
      neverReply();
      var released = false;
      var attached = false;
      AudioRoute? route;
      VoiceAudioSession.release().then((_) => released = true);
      VoiceAudioSession.attachEffects(3).then((_) => attached = true);
      VoiceAudioSession.getCurrentRoute().then((r) => route = r);
      async.elapse(VoiceAudioSession.quickLimit);
      expect(released, isTrue);
      expect(attached, isTrue);
      expect(route, AudioRoute.unknown);
    });
  });

  test('a prompt reply still comes straight through', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCurrentRoute') return 'wired';
      return null;
    });
    expect(await VoiceAudioSession.getCurrentRoute(), AudioRoute.wired);
  });
}
