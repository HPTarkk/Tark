import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/log_budget.dart';

/// The arithmetic behind "the log cannot get bigger than this".
///
/// Everything here is pure, so it pins the rules the file store depends on
/// without going near a disk: the range is closed at both ends, the ladder
/// stays inside it, and a segment is always a genuine fraction of the whole.
void main() {
  group('range', () {
    test('clamps below the floor and above the ceiling', () {
      expect(LogBudget.clamp(0), LogBudget.minBytes);
      expect(LogBudget.clamp(-1), LogBudget.minBytes);
      expect(LogBudget.clamp(1024), LogBudget.minBytes);
      expect(LogBudget.clamp(1 << 40), LogBudget.maxBytes);
    });

    test('passes through a value already inside the range', () {
      expect(LogBudget.clamp(LogBudget.defaultBytes), LogBudget.defaultBytes);
    });

    test('the default sits inside the range', () {
      expect(LogBudget.defaultBytes, greaterThanOrEqualTo(LogBudget.minBytes));
      expect(LogBudget.defaultBytes, lessThanOrEqualTo(LogBudget.maxBytes));
    });
  });

  group('ladder', () {
    test('runs from the floor to the ceiling, strictly ascending', () {
      expect(LogBudget.steps.first, LogBudget.minBytes);
      expect(LogBudget.steps.last, LogBudget.maxBytes);
      for (var i = 1; i < LogBudget.steps.length; i++) {
        expect(LogBudget.steps[i], greaterThan(LogBudget.steps[i - 1]));
      }
    });

    test('every rung round-trips through its own index', () {
      for (var i = 0; i < LogBudget.steps.length; i++) {
        expect(LogBudget.stepIndexFor(LogBudget.steps[i]), i);
      }
    });

    test('an off-ladder value snaps to the nearest rung by ratio', () {
      // 9 MB is nearer 8 than 16 either way; 300 KB is nearer 250 than 500 in
      // ratio terms even though it is equidistant in absolute bytes.
      expect(
        LogBudget.steps[LogBudget.stepIndexFor(9 * 1024 * 1024)],
        8 * 1024 * 1024,
      );
      expect(LogBudget.steps[LogBudget.stepIndexFor(300 * 1024)], 250 * 1024);
    });

    test('out-of-range values still land on a rung', () {
      expect(LogBudget.stepIndexFor(0), 0);
      expect(
        LogBudget.stepIndexFor(1 << 40),
        LogBudget.steps.length - 1,
      );
    });
  });

  group('segments', () {
    test('a segment is always a real fraction of the budget', () {
      for (final step in LogBudget.steps) {
        final segment = LogBudget.segmentBytes(step);
        expect(segment, greaterThan(0));
        expect(
          segment,
          lessThan(step),
          reason: 'a segment as big as the budget would make rotation a wipe',
        );
      }
    });

    test('a full ring of segments fits the budget', () {
      for (final step in LogBudget.steps) {
        expect(
          LogBudget.segmentBytes(step) * LogBudget.segments,
          lessThanOrEqualTo(step),
        );
      }
    });
  });

  group('format', () {
    test('renders round numbers without decimals', () {
      expect(LogBudget.format(20 * 1024), '20 KB');
      expect(LogBudget.format(500 * 1024), '500 KB');
      expect(LogBudget.format(8 * 1024 * 1024), '8 MB');
      expect(LogBudget.format(100 * 1024 * 1024), '100 MB');
    });

    test('keeps one decimal for values between units', () {
      expect(LogBudget.format(1536 * 1024), '1.5 MB');
      expect(LogBudget.format(512), '512 B');
    });

    test('every rung formats to a whole number', () {
      for (final step in LogBudget.steps) {
        expect(LogBudget.format(step), isNot(contains('.')));
      }
    });
  });
}
