import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/update/domain/entity/update_feed.dart';

Map<String, dynamic> _json({
  Object? latestVersion = '1.0.22',
  Object? latestBuild = 32,
  Object? minimumBuild = 0,
  Object? url = 'https://cafebazaar.ir/app/com.b1101.tark',
  Object? notes,
}) => {
  'android': {
    'latestVersion': latestVersion,
    'latestBuild': latestBuild,
    'minimumBuild': minimumBuild,
    'url': url,
    'notes': ?notes,
  },
};

void main() {
  group('UpdateFeed.fromJson', () {
    test('reads a well-formed feed', () {
      final feed = UpdateFeed.fromJson(
        _json(
          notes: {
            'en': ['Faster join', '  ', 42],
            'fa': ['اتصال سریع‌تر'],
          },
        ),
      );
      expect(feed.latestVersion, '1.0.22');
      expect(feed.latestBuild, 32);
      expect(feed.minimumBuild, 0);
      expect(feed.url.host, 'cafebazaar.ir');
      // Blank and non-string lines are dropped, not shown as empty bullets.
      expect(feed.notesFor('en'), ['Faster join']);
      expect(feed.notesFor('fa'), ['اتصال سریع‌تر']);
    });

    test('notes fall back to English, then to none', () {
      final feed = UpdateFeed.fromJson(_json(notes: {'en': ['x']}));
      expect(feed.notesFor('fa'), ['x']);
      expect(UpdateFeed.fromJson(_json()).notesFor('fa'), isEmpty);
    });

    test('a missing minimumBuild means nothing is required', () {
      final json = _json();
      (json['android'] as Map).remove('minimumBuild');
      expect(UpdateFeed.fromJson(json).minimumBuild, 0);
    });

    for (final (name, json) in [
      ('no android object', <String, dynamic>{}),
      ('empty version', _json(latestVersion: '')),
      ('string build', _json(latestBuild: '32')),
      ('zero build', _json(latestBuild: 0)),
      ('minimum above latest', _json(minimumBuild: 33)),
      ('http url', _json(url: 'http://cafebazaar.ir/app/com.b1101.tark')),
      ('no url', _json(url: null)),
    ]) {
      test('rejects $name', () {
        expect(
          () => UpdateFeed.fromJson(json),
          throwsA(isA<UpdateFeedException>()),
        );
      });
    }
  });

  group('decideUpdate', () {
    final now = DateTime(2026, 9, 28, 12);
    UpdateFeed feed({int latest = 32, int minimum = 0}) => UpdateFeed.fromJson(
      _json(latestBuild: latest, minimumBuild: minimum),
    );

    test('up to date: nothing', () {
      expect(decideUpdate(feed: feed(), installedBuild: 32, now: now), isNull);
      // A build newer than the feed (a local build) is not told to downgrade.
      expect(decideUpdate(feed: feed(), installedBuild: 40, now: now), isNull);
    });

    test('behind latest: optional', () {
      final offer = decideUpdate(
        feed: feed(),
        installedBuild: 31,
        installedVersion: '1.0.21',
        now: now,
      );
      expect(offer?.urgency, UpdateUrgency.optional);
      expect(offer?.installedVersion, '1.0.21');
    });

    test('below minimum: required', () {
      expect(
        decideUpdate(
          feed: feed(minimum: 30),
          installedBuild: 29,
          now: now,
        )?.urgency,
        UpdateUrgency.required,
      );
      // At the minimum is allowed through, as optional.
      expect(
        decideUpdate(
          feed: feed(minimum: 30),
          installedBuild: 30,
          now: now,
        )?.urgency,
        UpdateUrgency.optional,
      );
    });

    test('a snooze quiets that build for three days only', () {
      UpdateOffer? at(Duration since, {int snoozedBuild = 32}) => decideUpdate(
        feed: feed(),
        installedBuild: 31,
        now: now,
        snoozedBuild: snoozedBuild,
        snoozedAt: now.subtract(since),
      );
      expect(at(const Duration(days: 1)), isNull);
      expect(at(const Duration(days: 3))?.urgency, UpdateUrgency.optional);
      // A newer build than the one put off asks again at once.
      expect(
        at(const Duration(hours: 1), snoozedBuild: 31)?.urgency,
        UpdateUrgency.optional,
      );
    });

    test('nothing snoozes a required update', () {
      expect(
        decideUpdate(
          feed: feed(minimum: 32),
          installedBuild: 31,
          now: now,
          snoozedBuild: 32,
          snoozedAt: now,
        )?.urgency,
        UpdateUrgency.required,
      );
    });
  });
}
