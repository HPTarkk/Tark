import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/stall_watchdog.dart';

void main() {
  const watchdog = StallWatchdog(
    stallTimeout: Duration(seconds: 3),
    minRestartInterval: Duration(seconds: 5),
    watchdogInterval: Duration(seconds: 2),
    watchdogJitter: Duration(milliseconds: 500),
  );

  final base = DateTime(2026, 1, 1, 12, 0, 0);

  group('screen-off nap', () {
    test(
      'a long nap credits the gap onto lastInputAt and does not restart',
      () {
        // Frames stopped arriving right before the phone locked; the
        // watchdog tick itself only fires again 40s later, proving the
        // isolate was suspended for the nap rather than the mic going
        // silent while awake.
        final lastInputAt = base;
        final lastWatchdogAt = base;
        final now = base.add(const Duration(seconds: 40));

        final result = watchdog.check(
          now: now,
          lastInputAt: lastInputAt,
          lastWatchdogAt: lastWatchdogAt,
          lastRestartAt: DateTime.fromMillisecondsSinceEpoch(0),
        );

        expect(
          result.shouldRestart,
          isFalse,
          reason: 'a nap must not read as a stall',
        );
        // The credited input time should track the gap: the mic is judged as
        // having gone quiet no more than a fresh [stallTimeout] ago.
        expect(
          now.difference(result.creditedInputAt),
          lessThanOrEqualTo(watchdog.stallTimeout),
        );
      },
    );

    test('several consecutive naps in a row still never restart', () {
      var lastInputAt = base;
      var lastWatchdogAt = base;
      var lastRestartAt = DateTime.fromMillisecondsSinceEpoch(0);
      var now = base;

      // Naps modeled on the real field-log gaps that motivated this fix.
      for (final napSeconds in [4.8, 16.6, 31.2, 33.7]) {
        now = now.add(Duration(milliseconds: (napSeconds * 1000).round()));
        final result = watchdog.check(
          now: now,
          lastInputAt: lastInputAt,
          lastWatchdogAt: lastWatchdogAt,
          lastRestartAt: lastRestartAt,
        );
        expect(result.shouldRestart, isFalse);
        lastWatchdogAt = now;
        lastInputAt = result.creditedInputAt;
        // A frame arrives right after each resume, same as production.
        lastInputAt = now;
      }
    });
  });

  group('a genuine stall while awake', () {
    test('restarts once the mic has been silent past stallTimeout', () {
      final lastInputAt = base;
      var lastWatchdogAt = base;
      var now = base;

      // Watchdog ticks on schedule (no suspension), mic stays silent.
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 2));
        final result = watchdog.check(
          now: now,
          lastInputAt: lastInputAt,
          lastWatchdogAt: lastWatchdogAt,
          lastRestartAt: DateTime.fromMillisecondsSinceEpoch(0),
        );
        lastWatchdogAt = now;
        if (now.difference(lastInputAt) >= watchdog.stallTimeout) {
          expect(result.shouldRestart, isTrue);
          return;
        }
        expect(result.shouldRestart, isFalse);
      }
      fail('expected a stall to be detected within the loop');
    });

    test('does not restart again inside minRestartInterval', () {
      // On-schedule tick, mic genuinely silent past stallTimeout — the only
      // thing blocking a restart here should be the cooldown.
      final lastInputAt = base.subtract(const Duration(seconds: 4));
      final lastWatchdogAt = base.subtract(const Duration(seconds: 2));
      final justRestartedAt = base.subtract(const Duration(seconds: 4));
      final now = base;

      final result = watchdog.check(
        now: now,
        lastInputAt: lastInputAt,
        lastWatchdogAt: lastWatchdogAt,
        lastRestartAt: justRestartedAt,
      );

      expect(
        result.shouldRestart,
        isFalse,
        reason: 'a restart 4s ago is still within the 5s cooldown',
      );
    });

    test('restarts again once minRestartInterval has passed', () {
      // On-schedule tick (no crediting kicks in) with a mic that has
      // genuinely been silent for longer than stallTimeout, and the last
      // restart well outside the cooldown.
      final lastInputAt = base.subtract(const Duration(seconds: 4));
      final lastWatchdogAt = base.subtract(const Duration(seconds: 2));
      final restartedAt = base.subtract(const Duration(seconds: 6));
      final now = base;

      final result = watchdog.check(
        now: now,
        lastInputAt: lastInputAt,
        lastWatchdogAt: lastWatchdogAt,
        lastRestartAt: restartedAt,
      );

      expect(result.shouldRestart, isTrue);
    });
  });

  group('ordinary scheduling jitter', () {
    test('lateness under watchdogJitter does not credit any gap', () {
      final lastInputAt = base;
      // Tick fires 2.2s after the previous one against a 2s interval — 200ms
      // late, under the 500ms jitter allowance.
      final lastWatchdogAt = base.subtract(
        const Duration(seconds: 2, milliseconds: 200),
      );
      final now = base;

      final result = watchdog.check(
        now: now,
        lastInputAt: lastInputAt,
        lastWatchdogAt: lastWatchdogAt,
        lastRestartAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

      expect(
        result.creditedInputAt,
        equals(lastInputAt),
        reason: 'ordinary jitter must not move the credited input time',
      );
    });
  });
}
