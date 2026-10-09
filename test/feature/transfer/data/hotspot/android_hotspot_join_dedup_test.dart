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
    joinCalls = 0;
    leaveCalls = 0;
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

  test(
    'same credentials coalesce while joining and stay stable once joined',
    () async {
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
    },
  );

  test(
    'explicit leave lets the same credentials perform a real retry',
    () async {
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
    },
  );

  testWidgets('a native join that never replies releases and can retry', (
    tester,
  ) async {
    HotspotJoinResult? result;
    unawaited(joiner.join(creds).then((value) => result = value));
    await tester.pump();
    expect(joinCalls, 1);

    // Android's requestNetwork gets 40 seconds, including its consent dialog.
    // A missing framework callback must still finish the app's wait.
    await tester.pump(const Duration(seconds: 51));
    await tester.pump();
    expect(result, HotspotJoinResult.declined);
    expect(leaveCalls, 1);

    final expiredNativeJoin = nativeJoin;
    nativeJoin = Completer<bool?>();
    HotspotJoinResult? retryResult;
    unawaited(joiner.join(creds).then((value) => retryResult = value));
    await tester.pump();
    expect(joinCalls, 2);
    expect(retryResult, isNull);

    // A callback from the expired request cannot turn a pending retry into a
    // joined lease. A second caller must still coalesce with the fresh request.
    expiredNativeJoin.complete(true);
    await tester.pump();
    HotspotJoinResult? duplicateResult;
    unawaited(
      AndroidWifiJoiner().join(creds).then((value) {
        duplicateResult = value;
      }),
    );
    await tester.pump();
    expect(duplicateResult, isNull);
    expect(joinCalls, 2);

    nativeJoin.complete(true);
    await tester.pump();
    expect(retryResult, HotspotJoinResult.joined);
    expect(duplicateResult, HotspotJoinResult.joined);
  });

  testWidgets('the native consent window stays open until its own deadline', (
    tester,
  ) async {
    nativeJoin = Completer<bool?>();
    HotspotJoinResult? result;
    unawaited(joiner.join(creds).then((value) => result = value));
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));

    expect(result, isNull);
    expect(leaveCalls, 0);
    nativeJoin.complete(true);
    await tester.pump();
    expect(result, HotspotJoinResult.joined);
  });

  testWidgets('timeout cleanup is bounded and serialized with retries', (
    tester,
  ) async {
    joiner = AndroidWifiJoiner(
      joinTimeout: const Duration(milliseconds: 10),
      releaseTimeout: const Duration(milliseconds: 10),
    );
    final neverRelease = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'join':
          joinCalls++;
          return nativeJoin.future;
        case 'leave':
          leaveCalls++;
          await neverRelease.future;
          return null;
      }
      return null;
    });

    HotspotJoinResult? result;
    unawaited(joiner.join(creds).then((value) => result = value));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 11));
    expect(leaveCalls, 1);
    expect(result, isNull);

    HotspotJoinResult? cleanupDuplicate;
    unawaited(
      joiner.join(creds).then((value) {
        cleanupDuplicate = value;
      }),
    );
    await tester.pump();
    expect(joinCalls, 1);
    await tester.pump(const Duration(milliseconds: 11));
    expect(result, HotspotJoinResult.declined);
    expect(cleanupDuplicate, HotspotJoinResult.declined);

    nativeJoin = Completer<bool?>()..complete(true);
    HotspotJoinResult? retryResult;
    unawaited(joiner.join(creds).then((value) => retryResult = value));
    await tester.pump();
    expect(joinCalls, 2);
    expect(retryResult, HotspotJoinResult.joined);
    // Complete the fake cleanup so tearDown's explicit leave can also reply.
    neverRelease.complete();
    await tester.pump();
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });

  testWidgets('a cancelled join cannot return joined from a late callback', (
    tester,
  ) async {
    nativeJoin = Completer<bool?>();
    HotspotJoinResult? result;
    unawaited(joiner.join(creds).then((value) => result = value));
    await tester.pump();
    HotspotJoinResult? duplicateResult;
    unawaited(
      AndroidWifiJoiner().join(creds).then((value) {
        duplicateResult = value;
      }),
    );
    await tester.pump();
    expect(joinCalls, 1);
    await joiner.leave();

    nativeJoin.complete(true);
    await tester.pump();
    expect(result, HotspotJoinResult.declined);
    expect(duplicateResult, HotspotJoinResult.declined);

    nativeJoin = Completer<bool?>();
    HotspotJoinResult? retryResult;
    unawaited(joiner.join(creds).then((value) => retryResult = value));
    await tester.pump();
    expect(joinCalls, 2);
    expect(retryResult, isNull);
    nativeJoin.complete(true);
    await tester.pump();
    expect(retryResult, HotspotJoinResult.joined);
  });

  testWidgets('an old deadline cannot release a replacement network', (
    tester,
  ) async {
    joiner = AndroidWifiJoiner(joinTimeout: const Duration(milliseconds: 10));
    final expiredNativeJoin = nativeJoin;
    HotspotJoinResult? result;
    unawaited(joiner.join(creds).then((value) => result = value));
    await tester.pump();
    await joiner.leave();
    expect(leaveCalls, 1);

    const replacement = HotspotCredentials(
      ssid: 'replacement-network',
      passphrase: 'replacement-password',
    );
    nativeJoin = Completer<bool?>()..complete(true);
    HotspotJoinResult? replacementResult;
    unawaited(
      AndroidWifiJoiner().join(replacement).then((value) {
        replacementResult = value;
      }),
    );
    await tester.pump();
    expect(replacementResult, HotspotJoinResult.joined);

    await tester.pump(const Duration(milliseconds: 11));
    expect(result, HotspotJoinResult.declined);
    expect(leaveCalls, 1);
    expiredNativeJoin.complete(true);
    await tester.pump();
    expect(
      await AndroidWifiJoiner().join(replacement),
      HotspotJoinResult.joined,
    );
    expect(joinCalls, 2);
  });

  test(
    'an unexpected native error declines and allows a fresh retry',
    () async {
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler(channel.name, (message) {
        final call = codec.decodeMethodCall(message);
        switch (call.method) {
          case 'join':
            joinCalls++;
            if (joinCalls == 1) {
              throw StateError('native transport unavailable');
            }
            return Future.value(codec.encodeSuccessEnvelope(true));
          case 'leave':
            leaveCalls++;
            if (leaveCalls == 1) {
              throw StateError('native release unavailable');
            }
            return Future.value(codec.encodeSuccessEnvelope(null));
        }
        return Future.value(codec.encodeSuccessEnvelope(null));
      });

      Object? joinError;
      HotspotJoinResult? result;
      await joiner
          .join(creds)
          .then<void>(
            (value) {
              result = value;
            },
            onError: (Object error) {
              joinError = error;
            },
          );
      expect(joinError, isNull);
      expect(result, HotspotJoinResult.declined);
      expect(leaveCalls, 1);

      expect(await AndroidWifiJoiner().join(creds), HotspotJoinResult.joined);
      expect(joinCalls, 2);
    },
  );

  testWidgets('different pending invites serialize association and release', (
    tester,
  ) async {
    const second = HotspotCredentials(
      ssid: 'second-network',
      passphrase: 'second-password',
    );
    const third = HotspotCredentials(
      ssid: 'third-network',
      passphrase: 'third-password',
    );
    final replies = <String, Completer<bool?>>{
      creds.ssid: Completer<bool?>(),
      second.ssid: Completer<bool?>(),
      third.ssid: Completer<bool?>(),
    };
    final releases = [Completer<void>(), Completer<void>()];
    final associations = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'join':
          final ssid = call.arguments['ssid'] as String;
          associations.add(ssid);
          return replies[ssid]!.future;
        case 'leave':
          final index = leaveCalls++;
          if (index < releases.length) await releases[index].future;
          return null;
      }
      return null;
    });

    final outcomes = <String, HotspotJoinResult>{};
    for (final credentials in [creds, second, third]) {
      unawaited(
        joiner.join(credentials).then((value) {
          outcomes[credentials.ssid] = value;
        }),
      );
      await tester.pump();
    }
    expect(associations, [creds.ssid]);
    replies[creds.ssid]!.complete(true);
    await tester.pump();
    expect(leaveCalls, 1);
    expect(associations, [creds.ssid]);
    expect(outcomes, {creds.ssid: HotspotJoinResult.joined});

    releases[0].complete();
    await tester.pump();
    expect(associations, [creds.ssid, second.ssid]);
    replies[second.ssid]!.complete(true);
    await tester.pump();
    expect(leaveCalls, 2);
    expect(associations, [creds.ssid, second.ssid]);

    releases[1].complete();
    await tester.pump();
    expect(associations, [creds.ssid, second.ssid, third.ssid]);
    replies[third.ssid]!.complete(true);
    await tester.pump();
    expect(outcomes, {
      creds.ssid: HotspotJoinResult.joined,
      second.ssid: HotspotJoinResult.joined,
      third.ssid: HotspotJoinResult.joined,
    });
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });
}
