import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/announcement/domain/entity/announcement.dart';

Map<String, dynamic> _entry([Map<String, dynamic> extra = const {}]) => {
  'id': 'hello',
  'category': 'news',
  'title': {'en': 'Hello', 'fa': 'سلام'},
  'body': 'Body text',
  ...extra,
};

AnnouncementContext _ctx({
  Set<String> seen = const {},
  bool signedIn = false,
  bool canSignIn = true,
  bool monetized = false,
  bool premium = false,
  String platform = 'android',
  int build = 40,
  DateTime? now,
}) => AnnouncementContext(
  now: now ?? DateTime.utc(2026, 11, 10),
  build: build,
  platform: platform,
  seen: seen,
  signedIn: signedIn,
  canSignIn: canSignIn,
  monetized: monetized,
  premium: premium,
);

List<String> _pick(
  List<Map<String, dynamic>> entries,
  AnnouncementContext ctx,
) => pickAnnouncements(
  AnnouncementFeed.fromJson({'announcements': entries}),
  ctx,
).map((a) => a.id).toList();

void main() {
  group('parsing', () {
    test('a full entry reads every field', () {
      final a = Announcement.fromJson(
        _entry({
          'category': 'gift',
          'highlight': {'en': '3 months free', 'fa': '۳ ماه رایگان'},
          'action': {
            'type': 'signIn',
            'label': {'en': 'Sign up free'},
          },
          'audience': 'signedOut',
          'startsAt': '2026-11-05T00:00:00+03:30',
          'endsAt': '2026-12-05T00:00:00Z',
          'minBuild': 39,
          'maxBuild': 60,
          'platforms': ['android'],
          'priority': 5,
        }),
      );
      expect(a.category, AnnouncementCategory.gift);
      expect(a.title.of('fa'), 'سلام');
      expect(a.body.of('fa'), 'Body text', reason: 'falls back to English');
      expect(a.highlight.of('en'), '3 months free');
      expect(a.action!.type, AnnouncementActionType.signIn);
      expect(a.action!.label.of('fa'), 'Sign up free');
      expect(a.audience, AnnouncementAudience.signedOut);
      expect(a.startsAt, DateTime.utc(2026, 11, 4, 20, 30));
      expect(a.minBuild, 39);
      expect(a.maxBuild, 60);
      expect(a.platforms, {'android'});
      expect(a.priority, 5);
    });

    test('one bad entry is dropped, the rest survive', () {
      final feed = AnnouncementFeed.fromJson({
        'announcements': [
          _entry({'id': 'good'}),
          _entry({'id': 'bad', 'category': 'party'}),
          'not an object',
          _entry({'id': 'good'}),
          _entry({
            'id': 'nolink',
            'action': {'type': 'link', 'url': 'http://x.ir'},
          }),
          _entry({
            'id': 'noscreen',
            'action': {'type': 'screen', 'screen': 'walkie'},
          }),
          _entry({'id': 'nozone', 'startsAt': '2026-11-05T00:00:00'}),
          _entry({
            'id': 'backwards',
            'startsAt': '2026-11-05T00:00:00Z',
            'endsAt': '2026-11-04T00:00:00Z',
          }),
          _entry({'id': 'Upper'}),
          _entry({
            'id': 'notitle',
            'title': {'en': '  '},
          }),
        ],
      });
      expect(feed.announcements.map((a) => a.id), ['good']);
      expect(feed.rejected, hasLength(9));
      expect(feed.rejected.join('\n'), contains('"bad": "category"'));
      expect(feed.rejected.join('\n'), contains('the same id twice'));
    });

    test('a file without the list is no feed at all', () {
      expect(
        () => AnnouncementFeed.fromJson({'android': {}}),
        throwsA(isA<AnnouncementFormatException>()),
      );
    });

    test('a link must be https and a screen must be on the list', () {
      final link = Announcement.fromJson(
        _entry({
          'action': {'type': 'link', 'url': 'https://tarkk.ir/x'},
        }),
      );
      expect(link.action!.url, Uri.parse('https://tarkk.ir/x'));
      final screen = Announcement.fromJson(
        _entry({
          'action': {'type': 'screen', 'screen': 'profile'},
        }),
      );
      expect(screen.action!.screen, 'profile');
    });
  });

  group('picking', () {
    test('seen ones never come back', () {
      expect(_pick([_entry()], _ctx(seen: {'hello'})), isEmpty);
      expect(_pick([_entry()], _ctx()), ['hello']);
    });

    test('dates: from startsAt up to, not including, endsAt', () {
      final e = _entry({
        'startsAt': '2026-11-10T00:00:00Z',
        'endsAt': '2026-11-11T00:00:00Z',
      });
      expect(_pick([e], _ctx(now: DateTime.utc(2026, 11, 9, 23, 59))), isEmpty);
      expect(_pick([e], _ctx(now: DateTime.utc(2026, 11, 10))), ['hello']);
      expect(_pick([e], _ctx(now: DateTime.utc(2026, 11, 11))), isEmpty);
    });

    test('builds and platforms', () {
      final e = _entry({'minBuild': 40, 'maxBuild': 41});
      expect(_pick([e], _ctx(build: 39)), isEmpty);
      expect(_pick([e], _ctx(build: 41)), ['hello']);
      expect(_pick([e], _ctx(build: 42)), isEmpty);
      expect(
        _pick([_entry()], _ctx(platform: 'web')),
        isEmpty,
        reason: 'the web guest only gets what names it',
      );
      expect(
        _pick([
          _entry({
            'platforms': ['ios'],
          }),
        ], _ctx()),
        isEmpty,
      );
      expect(
        _pick([
          _entry({
            'platforms': ['ios'],
          }),
        ], _ctx(platform: 'ios')),
        ['hello'],
      );
    });

    test('a sign-up offer only reaches someone who can still sign up', () {
      final offer = _entry({
        'audience': 'signedOut',
        'action': {'type': 'signIn'},
      });
      expect(_pick([offer], _ctx()), ['hello']);
      expect(_pick([offer], _ctx(signedIn: true)), isEmpty);
      expect(
        _pick([offer], _ctx(canSignIn: false)),
        isEmpty,
        reason: 'no accounts on this build: a button to nowhere',
      );
      // The action alone also rules it out, whatever the audience says.
      final loose = _entry({
        'action': {'type': 'signIn'},
      });
      expect(_pick([loose], _ctx(signedIn: true)), isEmpty);
    });

    test('free and premium only mean something where Tarkk is sold', () {
      final free = _entry({'id': 'free', 'audience': 'free'});
      final premium = _entry({'id': 'premium', 'audience': 'premium'});
      expect(_pick([free, premium], _ctx()), isEmpty);
      expect(_pick([free, premium], _ctx(monetized: true)), ['free']);
      expect(_pick([free, premium], _ctx(monetized: true, premium: true)), [
        'premium',
      ]);
      expect(
        _pick([
          _entry({'audience': 'signedIn'}),
        ], _ctx(signedIn: true)),
        ['hello'],
      );
    });

    test('priority first, then newest, then file order; at most three', () {
      final ids = _pick([
        _entry({'id': 'a'}),
        _entry({'id': 'b', 'priority': 2}),
        _entry({'id': 'c', 'startsAt': '2026-11-02T00:00:00Z'}),
        _entry({'id': 'd', 'startsAt': '2026-11-03T00:00:00Z'}),
        _entry({'id': 'e'}),
      ], _ctx());
      expect(ids, ['b', 'd', 'c']);
    });
  });
}
