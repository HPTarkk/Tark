import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/recovery/bounded_retry.dart';

/// Near-zero backoff so the tests exercise the cycle, not the clock.
BoundedRetry fast({int maxAttempts = 4, int honestAfter = 2}) => BoundedRetry(
  name: 'test',
  maxAttempts: maxAttempts,
  honestAfter: honestAfter,
  backoff: (_) => const Duration(milliseconds: 1),
);

void main() {
  group('a cycle that gets there', () {
    test('a body that works first time is called exactly once', () async {
      final retry = fast();
      var calls = 0;

      final ok = await retry.run((_) async {
        calls++;
        return true;
      });

      expect(ok, isTrue);
      expect(calls, 1);
      expect(retry.phase, RetryPhase.succeeded);
      retry.dispose();
    });

    test('failures before a success are absorbed silently', () async {
      final retry = fast();
      final seen = <RetryPhase>[];
      retry.phases.listen(seen.add);
      var calls = 0;

      final ok = await retry.run((attempt) async {
        calls++;
        return attempt == 3;
      });
      await Future<void>.delayed(Duration.zero);

      expect(ok, isTrue);
      expect(calls, 3);
      // The user is never shown fix options for a problem that cleared on
      // its own — [RetryPhase.exhausted] is the only phase that offers them.
      expect(seen, isNot(contains(RetryPhase.exhausted)));
      retry.dispose();
    });

    test('a throwing body is just a failed attempt, not a crash', () async {
      final retry = fast();
      var calls = 0;

      final ok = await retry.run((attempt) async {
        calls++;
        if (attempt < 2) throw StateError('radio busy');
        return true;
      });

      expect(ok, isTrue);
      expect(calls, 2);
      retry.dispose();
    });
  });

  group('a cycle that does not', () {
    test('stops at maxAttempts and lands on exhausted', () async {
      final retry = fast(maxAttempts: 4);
      var calls = 0;

      final ok = await retry.run((_) async {
        calls++;
        return false;
      });

      expect(ok, isFalse);
      expect(calls, 4);
      expect(retry.phase, RetryPhase.exhausted);
      retry.dispose();
    });

    test('softens to stillTrying only after honestAfter attempts', () async {
      final retry = fast(maxAttempts: 4, honestAfter: 2);
      final seen = <RetryPhase>[];
      retry.phases.listen(seen.add);
      final phaseAtAttempt = <int, RetryPhase>{};

      await retry.run((attempt) async {
        phaseAtAttempt[attempt] = retry.phase;
        return false;
      });
      await Future<void>.delayed(Duration.zero);

      // Neutral first, honest later — a transient hiccup never gets error
      // styling, but a long wait stops looking frozen.
      expect(phaseAtAttempt[1], RetryPhase.working);
      expect(phaseAtAttempt[2], RetryPhase.working);
      expect(phaseAtAttempt[3], RetryPhase.stillTrying);
      expect(phaseAtAttempt[4], RetryPhase.stillTrying);
      expect(seen.last, RetryPhase.exhausted);
      retry.dispose();
    });
  });

  group('failures retrying cannot fix', () {
    test('RetryAbort ends the cycle immediately, at exhausted', () async {
      final retry = fast();
      var calls = 0;

      final ok = await retry.run((_) async {
        calls++;
        throw const RetryAbort();
      });

      expect(ok, isFalse);
      // "Turn your tethering off" must not cost the user four attempts'
      // worth of waiting before they're told.
      expect(calls, 1);
      expect(retry.phase, RetryPhase.exhausted);
      retry.dispose();
    });
  });

  group('abandoning', () {
    test('cancel stops further attempts', () async {
      final retry = BoundedRetry(
        name: 'test',
        maxAttempts: 5,
        backoff: (_) => const Duration(milliseconds: 40),
      );
      var calls = 0;

      final running = retry.run((_) async {
        calls++;
        return false;
      });
      // Let the first attempt land, then pull the rug mid-backoff.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      retry.cancel();
      final ok = await running;

      expect(ok, isFalse);
      expect(calls, 1);
      // Cancelled is not failed: a user who walked away is not shown a card.
      expect(retry.phase, isNot(RetryPhase.exhausted));
      retry.dispose();
    });

    test('a second run supersedes the first', () async {
      final retry = BoundedRetry(
        name: 'test',
        maxAttempts: 5,
        backoff: (_) => const Duration(milliseconds: 30),
      );
      var first = 0;
      var second = 0;

      final a = retry.run((_) async {
        first++;
        return false;
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = retry.run((_) async {
        second++;
        return true;
      });

      expect(await a, isFalse);
      expect(await b, isTrue);
      // The superseded cycle stopped where it was rather than racing the
      // new one — two cycles dialling at once is how a radio gets wedged.
      expect(first, 1);
      expect(second, 1);
      retry.dispose();
    });

    test('emits nothing after dispose', () async {
      final retry = fast();
      final seen = <RetryPhase>[];
      retry.phases.listen(seen.add);
      retry.dispose();

      final ok = await retry.run((_) async => false);
      await Future<void>.delayed(Duration.zero);

      expect(ok, isFalse);
      expect(seen, isEmpty);
    });
  });
}
