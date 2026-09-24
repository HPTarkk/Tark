import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:tark/feature/transfer/api/pre_live_hotspot_bootstrap.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';

void main() {
  const credentials = HotspotCredentials(
    ssid: 'DIRECT-TARK',
    passphrase: 'ridewithme',
  );

  tearDown(() => GetIt.instance.reset());

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
