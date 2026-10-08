import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/data/media_control.dart';
import 'package:tark/feature/audio/data/system_audio_capture.dart';
import 'package:tark/feature/audio/domain/capture_health.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('tark/system_audio');
  const media = MethodChannel('tark/media_control');
  const frames = MethodChannel('tark/system_audio/frames');
  const hdFrames = MethodChannel('tark/system_audio/hd_frames');
  const codec = StandardMethodCodec();
  late List<MethodCall> calls;
  late List<String> eventCalls;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> emit(String channel, Object? payload) async {
    // ignore: deprecated_member_use
    await messenger.handlePlatformMessage(
      channel,
      codec.encodeSuccessEnvelope(payload),
      (_) {},
    );
    await flush();
  }

  setUp(() {
    SystemAudioCapture.debugIsAndroid = true;
    MediaControl.debugIsAndroid = true;
    calls = [];
    eventCalls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isSupported' || 'start' => true,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(media, (_) async => false);
    for (final channel in [frames, hdFrames]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        eventCalls.add('${channel.name}:${call.method}');
        return null;
      });
    }
  });

  tearDown(() async {
    await SystemAudioCapture.stop();
    await flush();
    SystemAudioCapture.debugIsAndroid = null;
    MediaControl.debugIsAndroid = null;
    for (final channel in [methods, media, frames, hdFrames]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test(
    'unsupported platform publishes voice-only health without consent',
    () async {
      SystemAudioCapture.debugIsAndroid = false;
      expect(await SystemAudioCapture.isSupported, isFalse);
      expect(await SystemAudioCapture.start(), isFalse);
      expect(calls, isEmpty);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.unsupported,
      );
      expect(SystemAudioCapture.healthSnapshot.mayTransmitMedia, isFalse);
    },
  );

  test('failed or absent support query never opens consent', () async {
    for (final response in [null, PlatformException(code: 'unsupported')]) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (response is PlatformException) throw response;
        return response;
      });
      expect(await SystemAudioCapture.start(), isFalse);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.unsupported,
      );
    }
    expect(calls.every((call) => call.method == 'isSupported'), isTrue);
  });

  test(
    'consent refusal and start failure retain distinct stopped reasons',
    () async {
      for (final response in [
        false,
        null,
        PlatformException(code: 'projection_failed'),
        MissingPluginException(),
      ]) {
        messenger.setMockMethodCallHandler(methods, (call) async {
          if (call.method == 'isSupported') return true;
          if (call.method != 'start') return null;
          if (response is Exception) throw response;
          return response;
        });
        expect(await SystemAudioCapture.start(), isFalse);
        expect(
          SystemAudioCapture.healthSnapshot.state,
          CaptureHealthState.stopped,
        );
        expect(
          SystemAudioCapture.healthSnapshot.reasonCode,
          response is Exception
              ? 'capture_start_failed'
              : 'capture_start_declined',
        );
      }
    },
  );

  test(
    'foreground launch rejection withholds media and permits a fresh retry',
    () async {
      var rejectLaunch = true;
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'isSupported') return true;
        if (call.method == 'start') {
          if (rejectLaunch) {
            throw PlatformException(
              code: 'capture_start_failed',
              message: 'Foreground service launch rejected',
            );
          }
          return true;
        }
        return null;
      });
      final received = <List<double>>[];
      final subscription = SystemAudioCapture.frames.listen(received.add);
      await flush();
      expect(await SystemAudioCapture.start(), isFalse);
      expect(
        SystemAudioCapture.healthSnapshot.reasonCode,
        'capture_start_failed',
      );
      await emit(frames.name, Float64List.fromList([0.2, -0.2]));
      expect(received, isEmpty);
      rejectLaunch = false;
      expect(await SystemAudioCapture.start(), isTrue);
      await emit(frames.name, Float64List.fromList([0.2, -0.2]));
      expect(received.single, [0.2, -0.2]);
      await subscription.cancel();
    },
  );

  test(
    'silence is withheld; audible callbacks pass; stop suppresses late frames',
    () async {
      final received = <List<double>>[];
      final subscription = SystemAudioCapture.frames.listen(received.add);
      await flush();
      expect(await SystemAudioCapture.start(), isTrue);
      await emit(frames.name, Float64List.fromList([0, 0, 0, 0]));
      expect(received, isEmpty);
      await emit(frames.name, Float64List.fromList([0.2, -0.2, 0.1, -0.1]));
      expect(received.single, [0.2, -0.2, 0.1, -0.1]);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.audible,
      );
      expect(
        SystemAudioCapture.healthSnapshot.timeToFirstAudibleFrameMs,
        isNotNull,
      );
      await SystemAudioCapture.stop();
      await emit(frames.name, Float64List.fromList([0.8, -0.8]));
      expect(received.length, 1);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.stopped,
      );
      await subscription.cancel();
    },
  );

  test(
    'invalid and nonfinite native frames cannot become audible evidence',
    () async {
      final received = <List<double>>[];
      final errors = <Object>[];
      final subscription = SystemAudioCapture.frames.listen(
        received.add,
        onError: errors.add,
      );
      await flush();
      expect(await SystemAudioCapture.start(), isTrue);
      for (final payload in [
        null,
        'wrong native payload',
        [0.2, -0.2],
        Float64List(0),
        Float64List.fromList([double.infinity, 0.2]),
        Float64List.fromList([double.nan, 0.2]),
      ]) {
        await emit(frames.name, payload);
      }
      expect(received, isEmpty);
      expect(errors, isEmpty);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.starting,
      );
      await emit(frames.name, Float64List.fromList([0.2, -0.2]));
      expect(received.single, [0.2, -0.2]);
      await subscription.cancel();
    },
  );

  test(
    'HD keeps stereo interleaving and rejects incomplete channel frames',
    () async {
      final received = <List<double>>[];
      final subscription = SystemAudioCapture.hdFrames.listen(received.add);
      await flush();
      await SystemAudioCapture.start();
      await emit(hdFrames.name, Float64List.fromList([0.2, -0.2, 0.3]));
      expect(received, isEmpty);
      await emit(hdFrames.name, Float64List.fromList([0.2, -0.2, 0.3, -0.3]));
      expect(received.single, [0.2, -0.2, 0.3, -0.3]);
      expect(SystemAudioCapture.hdFormat.sampleRateHz, 48000);
      expect(SystemAudioCapture.hdFormat.channels, 2);
      await subscription.cancel();
    },
  );

  test(
    'multiple consumers share native subscription and cancel on last release',
    () async {
      final first = <List<double>>[];
      final second = <List<double>>[];
      final a = SystemAudioCapture.frames.listen(first.add);
      final b = SystemAudioCapture.frames.listen(second.add);
      await flush();
      expect(
        eventCalls.where((call) => call == '${frames.name}:listen').length,
        1,
      );
      await SystemAudioCapture.start();
      await emit(frames.name, Float64List.fromList([0.2, -0.2]));
      expect(first, second);
      await a.cancel();
      expect(
        eventCalls.where((call) => call == '${frames.name}:cancel'),
        isEmpty,
      );
      await b.cancel();
      await flush();
      expect(
        eventCalls.where((call) => call == '${frames.name}:cancel').length,
        1,
      );
    },
  );

  test(
    'native stream errors propagate and a later good frame recovers',
    () async {
      final received = <List<double>>[];
      final errors = <Object>[];
      final subscription = SystemAudioCapture.frames.listen(
        received.add,
        onError: errors.add,
      );
      await flush();
      await SystemAudioCapture.start();
      // ignore: deprecated_member_use
      await messenger.handlePlatformMessage(
        frames.name,
        codec.encodeErrorEnvelope(
          code: 'capture_lost',
          message: 'projection stopped',
        ),
        (_) {},
      );
      await flush();
      expect(errors.single, isA<PlatformException>());
      await emit(frames.name, Float64List.fromList([0.2, -0.2]));
      expect(received.length, 1);
      await subscription.cancel();
    },
  );

  test('stop cancels start while native support query is pending', () async {
    final support = Completer<bool>();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'isSupported') return support.future;
      return true;
    });
    final pending = SystemAudioCapture.start();
    await flush();
    await SystemAudioCapture.stop();
    support.complete(true);
    expect(await pending, isFalse);
    expect(calls.map((call) => call.method), ['isSupported', 'stop']);
    expect(SystemAudioCapture.healthSnapshot.state, CaptureHealthState.stopped);
  });

  test(
    'late accepted consent is stopped again without reviving capture',
    () async {
      final consent = Completer<bool>();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'isSupported') return true;
        if (call.method == 'start') return consent.future;
        return null;
      });
      final pending = SystemAudioCapture.start();
      await flush();
      await SystemAudioCapture.stop();
      consent.complete(true);
      expect(await pending, isFalse);
      expect(calls.map((call) => call.method), [
        'isSupported',
        'start',
        'stop',
        'stop',
      ]);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.stopped,
      );
    },
  );

  for (final oldRequestFails in [false, true]) {
    test(
      'older ${oldRequestFails ? 'failed' : 'accepted'} consent cannot stop a newer owner',
      () async {
        final oldConsent = Completer<bool>();
        var starts = 0;
        messenger.setMockMethodCallHandler(methods, (call) async {
          calls.add(call);
          if (call.method == 'isSupported') return true;
          if (call.method == 'start') {
            starts++;
            return starts == 1 ? oldConsent.future : true;
          }
          return null;
        });
        final oldRequest = SystemAudioCapture.start();
        await flush();
        await SystemAudioCapture.stop();
        expect(await SystemAudioCapture.start(), isTrue);
        if (oldRequestFails) {
          oldConsent.completeError(
            PlatformException(code: 'old_consent_failed'),
          );
        } else {
          oldConsent.complete(true);
        }
        expect(await oldRequest, isFalse);
        expect(calls.where((call) => call.method == 'stop').length, 1);
        expect(
          SystemAudioCapture.healthSnapshot.state,
          CaptureHealthState.starting,
        );
      },
    );
  }

  test('health refresh confirms access before probing other media', () async {
    final mediaCalls = <String>[];
    messenger.setMockMethodCallHandler(media, (call) async {
      mediaCalls.add(call.method);
      return true;
    });
    expect(await SystemAudioCapture.start(), isTrue);
    await flush();
    expect(mediaCalls, ['hasNotificationAccess', 'isOtherMediaPlaying']);
    // Playback elsewhere cannot bypass capture's own audible evidence guard.
    expect(
      SystemAudioCapture.healthSnapshot.state,
      CaptureHealthState.starting,
    );
  });

  test(
    'late health permission reply cannot publish after capture stopped',
    () async {
      final permission = Completer<bool>();
      final snapshots = <CaptureHealthSnapshot>[];
      final subscription = SystemAudioCapture.health.listen(snapshots.add);
      final mediaCalls = <String>[];
      messenger.setMockMethodCallHandler(media, (call) async {
        mediaCalls.add(call.method);
        if (call.method == 'hasNotificationAccess') return permission.future;
        return true;
      });
      await SystemAudioCapture.start();
      await flush();
      expect(mediaCalls, ['hasNotificationAccess']);
      await SystemAudioCapture.stop();
      await flush();
      final count = snapshots.length;
      permission.complete(true);
      await flush();
      expect(snapshots.length, count);
      expect(mediaCalls, ['hasNotificationAccess']);
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.stopped,
      );
      await subscription.cancel();
    },
  );

  testWidgets(
    'health timer avoids overlapping polls and declined restart cancels it',
    (tester) async {
      final permission = Completer<bool>();
      var polls = 0;
      messenger.setMockMethodCallHandler(media, (call) async {
        if (call.method == 'hasNotificationAccess') {
          polls++;
          return permission.future;
        }
        return false;
      });
      await SystemAudioCapture.start();
      await tester.pump(const Duration(milliseconds: 1600));
      expect(polls, 1);
      messenger.setMockMethodCallHandler(
        methods,
        (call) async => call.method == 'isSupported',
      );
      expect(await SystemAudioCapture.start(), isFalse);
      permission.complete(false);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(polls, 1);
      expect(
        SystemAudioCapture.healthSnapshot.reasonCode,
        'capture_start_declined',
      );
    },
  );

  test(
    'stop and local volume tolerate platform failures without stale health',
    () async {
      await SystemAudioCapture.start();
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        throw PlatformException(code: 'native_failure');
      });
      await SystemAudioCapture.setLocalVolume(0.37);
      final volume = calls.last;
      expect(volume.method, 'setLocalVolume');
      expect(volume.arguments, {'gain': 0.37});
      await SystemAudioCapture.stop();
      expect(
        SystemAudioCapture.healthSnapshot.state,
        CaptureHealthState.stopped,
      );
    },
  );
}
