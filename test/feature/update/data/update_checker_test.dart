import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/network/api_client.dart';
import 'package:tark/core/network/api_failure.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/feature/update/data/update_checker.dart';
import 'package:tark/feature/update/domain/entity/update_feed.dart';

class _FakeApi implements ApiClient {
  _FakeApi(this.answer);

  final Either<ApiFailure, Map<String, dynamic>> answer;
  final requested = <Uri>[];

  @override
  Future<Either<ApiFailure, Map<String, dynamic>>> getJson(
    Uri url, {
    Duration timeout = ApiLimits.timeout,
    int maxBytes = ApiLimits.maxBytes,
  }) async {
    requested.add(url);
    return answer;
  }

  @override
  void close() {}
}

Map<String, dynamic> _feed({int latest = 32, int minimum = 0}) => {
  'android': {
    'latestVersion': '1.0.22',
    'latestBuild': latest,
    'minimumBuild': minimum,
    'url': 'https://cafebazaar.ir/app/com.b1101.tark',
  },
};

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'Tark',
      packageName: 'com.b1101.tark',
      version: '1.0.21',
      buildNumber: '31',
      buildSignature: '',
    );
  });

  test('asks the feed with a fresh cache-busting query every time', () async {
    final api = _FakeApi(Right(_feed()));
    final checker = UpdateChecker(api, prefs);
    await checker.check();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await checker.check();

    expect(api.requested, hasLength(2));
    expect(api.requested.first.host, 'tarkk.ir');
    expect(api.requested.first.path, '/update.json');
    expect(api.requested.first.queryParameters['t'], isNotEmpty);
    expect(
      api.requested.first.queryParameters['t'],
      isNot(api.requested.last.queryParameters['t']),
    );
  });

  test('offers what the feed and the installed build decide', () async {
    final optional = await UpdateChecker(_FakeApi(Right(_feed())), prefs).check();
    expect(optional?.urgency, UpdateUrgency.optional);
    expect(optional?.installedVersion, '1.0.21');

    final required = await UpdateChecker(
      _FakeApi(Right(_feed(minimum: 32))),
      prefs,
    ).check();
    expect(required?.urgency, UpdateUrgency.required);

    final current = await UpdateChecker(
      _FakeApi(Right(_feed(latest: 31))),
      prefs,
    ).check();
    expect(current, isNull);
  });

  test('no signal, a bad status or a malformed file all mean nothing', () async {
    for (final failure in <ApiFailure>[
      const NetworkUnreachable('offline'),
      const RequestTimedOut('slow'),
      const BadStatus(404, 'gone'),
      const MalformedResponse('not json'),
    ]) {
      expect(await UpdateChecker(_FakeApi(Left(failure)), prefs).check(), isNull);
    }
    expect(
      await UpdateChecker(
        _FakeApi(const Right({'android': 'nope'})),
        prefs,
      ).check(),
      isNull,
    );
  });

  test('snoozing silences that build on the next check', () async {
    final checker = UpdateChecker(_FakeApi(Right(_feed())), prefs);
    final offer = (await checker.check())!;
    await checker.snooze(offer);

    expect(prefs.getInt(SettingsKeys.updateSnoozedBuild), 32);
    expect(await checker.check(), isNull);
  });
}
