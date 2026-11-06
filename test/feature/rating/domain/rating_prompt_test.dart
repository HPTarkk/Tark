import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/rating/domain/rating_prompt.dart';

void main() {
  late SharedPreferences prefs;
  late DateTime now;
  RatingPrompt rules() => RatingPrompt(prefs, clock: () => now);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime(2026, 11, 3, 12);
    RatingPrompt.platformOverride = true;
  });
  tearDown(() => RatingPrompt.platformOverride = null);

  /// A phone Tarkk has known for [days], with [rides] good rides behind it.
  Future<RatingPrompt> settled({int days = 4, int rides = 2}) async {
    final r = rules();
    now = now.subtract(Duration(days: days));
    await r.noteLaunch();
    now = now.add(Duration(days: days));
    for (var i = 0; i < rides; i++) {
      await r.recordRide(const Duration(minutes: 12));
    }
    return r;
  }

  test('asks after the second good ride once Tarkk has settled in', () async {
    final r = await settled(rides: 1);
    expect(r.takeAskMoment(), isFalse, reason: 'one good ride is not enough');
    await r.recordRide(const Duration(minutes: 6));
    expect(r.takeAskMoment(), isTrue);
    // The moment is spent: a later visit home does not ask again.
    expect(r.takeAskMoment(), isFalse);
  });

  test('short or lonely rides never count', () async {
    final r = await settled(rides: 0);
    await r.recordRide(const Duration(minutes: 4, seconds: 59));
    await r.recordRide(Duration.zero);
    await r.recordRide(const Duration(minutes: 3));
    expect(r.takeAskMoment(), isFalse);
    expect(r.eligible, isFalse);
  });

  test('never in the first days, however good the rides', () async {
    final r = await settled(days: 1, rides: 3);
    expect(r.takeAskMoment(), isFalse);
    now = now.add(const Duration(days: 3));
    await r.recordRide(const Duration(minutes: 30));
    expect(r.takeAskMoment(), isTrue);
  });

  test('only on arriving from a good ride, not on any visit home', () async {
    final r = await settled();
    expect(r.eligible, isTrue);
    // A fresh instance is a restart: the "just got back" moment is gone.
    expect(rules().takeAskMoment(), isFalse);
  });

  test(
    'waits a month between asks, needs new rides, and stops at three',
    () async {
      final r = await settled();
      for (var ask = 0; ask < RatingPrompt.maxAsks; ask++) {
        expect(r.takeAskMoment(), isTrue, reason: 'ask ${ask + 1}');
        await r.recordAsked();
        now = now.add(const Duration(days: 31));
        expect(r.eligible, isFalse, reason: 'each ask needs rides of its own');
        now = now.subtract(const Duration(days: 31));
        await r.recordRide(const Duration(minutes: 20));
        await r.recordRide(const Duration(minutes: 20));
        expect(r.takeAskMoment(), isFalse, reason: 'inside the cooldown');
        now = now.add(const Duration(days: 31));
        await r.recordRide(const Duration(minutes: 20));
      }
      expect(r.takeAskMoment(), isFalse, reason: 'three asks is the limit');
    },
  );

  test('never again once Bazaar was opened from the story', () async {
    final r = await settled();
    await r.recordOpened();
    expect(r.opened, isTrue);
    expect(r.takeAskMoment(), isFalse);
  });

  test('never where there is no Bazaar', () async {
    final r = await settled();
    RatingPrompt.platformOverride = false;
    expect(r.takeAskMoment(), isFalse);
  });

  test('noteLaunch keeps the first sighting', () async {
    final r = rules();
    await r.noteLaunch();
    now = now.add(const Duration(days: 10));
    await r.noteLaunch();
    for (var i = 0; i < 2; i++) {
      await r.recordRide(const Duration(minutes: 9));
    }
    expect(r.takeAskMoment(), isTrue);
  });

  test('the company clock only runs while someone else is there', () {
    final watch = _FakeStopwatch();
    final clock = RideCompanyClock(stopwatch: watch);
    clock.update(others: 0);
    expect(watch.isRunning, isFalse);
    clock.update(others: 2);
    expect(watch.isRunning, isTrue);
    clock.update(others: 1);
    expect(watch.starts, 1, reason: 'still company, the clock keeps going');
    clock.update(others: 0);
    expect(watch.isRunning, isFalse);
    clock.update(others: 1);
    expect(watch.starts, 2);
    clock.stop();
    expect(watch.isRunning, isFalse);
  });
}

class _FakeStopwatch implements Stopwatch {
  bool _running = false;
  int starts = 0;

  @override
  bool get isRunning => _running;

  @override
  void start() {
    _running = true;
    starts++;
  }

  @override
  void stop() => _running = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
