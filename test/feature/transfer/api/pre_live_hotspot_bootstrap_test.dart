import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/feature/transfer/api/pre_live_hotspot_bootstrap.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';

void main() {
  const credentials = HotspotCredentials(
    ssid: 'DIRECT-TARK',
    passphrase: 'ridewithme',
  );

  tearDown(() => GetIt.instance.reset());

  test('prepareHost hands back the AP the starter raised', () async {
    final result = await PreLiveHotspotBootstrap(
      starter: () async => credentials,
    ).prepareHost();

    expect(result, credentials);
  });

  test('prepareHost gives up on a start that never answers', () async {
    // Some phones never call startLocalOnlyHotspot back (seen with Wi-Fi
    // off). The Room must be able to say so instead of waiting for good.
    final never = Completer<HotspotCredentials?>();
    final result = await PreLiveHotspotBootstrap(
      starter: () => never.future,
      hostTimeout: const Duration(milliseconds: 20),
    ).prepareHost();

    expect(result, isNull);
  });

  group('reusing an access point already raised', () {
    test('shows it again while this phone still holds it', () {
      expect(
        PreLiveHotspotBootstrap.reusableCredentials(
          keeperState: HotspotLinkState.up,
          remembered: credentials,
          hosting: true,
        ),
        credentials,
      );
    });

    test('raises a fresh one when the remembered AP has gone off the air', () {
      // 2026-10-12: Wi-Fi switched back on took the AP down, the keeper still
      // said "up", and the code it showed named a network that was gone.
      expect(
        PreLiveHotspotBootstrap.reusableCredentials(
          keeperState: HotspotLinkState.up,
          remembered: credentials,
          hosting: false,
        ),
        isNull,
      );
    });

    test('never reuses a link that is not up', () {
      for (final state in [
        HotspotLinkState.idle,
        HotspotLinkState.recovering,
        HotspotLinkState.lost,
      ]) {
        expect(
          PreLiveHotspotBootstrap.reusableCredentials(
            keeperState: state,
            remembered: credentials,
            hosting: true,
          ),
          isNull,
        );
      }
    });
  });

  test('prepareHost has a time limit by default', () {
    expect(
      PreLiveHotspotBootstrap.defaultHostTimeout,
      lessThanOrEqualTo(const Duration(minutes: 1)),
    );
    expect(PreLiveHotspotBootstrap().hostTimeout, isNot(Duration.zero));
  });

  test('joinHost uses the injected joiner', () async {
    final seen = <HotspotCredentials>[];
    final result = await PreLiveHotspotBootstrap(
      joiner: (creds) async {
        seen.add(creds);
        return HotspotJoinResult.joined;
      },
    ).joinHost(credentials);

    expect(result, HotspotJoinResult.joined);
    expect(seen, [credentials]);
  });

  test(
    'without the bridge it still joins through the platform joiner',
    () async {
      final joiner = _FakeJoiner(HotspotJoinResult.wifiOff);
      GetIt.instance.registerSingleton<HotspotJoiner>(joiner);

      final result = await PreLiveHotspotBootstrap().joinHost(credentials);

      expect(result, HotspotJoinResult.wifiOff);
      expect(joiner.joined, [credentials]);
    },
  );
}

class _FakeJoiner implements HotspotJoiner {
  _FakeJoiner(this.result);

  final HotspotJoinResult result;
  final joined = <HotspotCredentials>[];

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    joined.add(credentials);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
