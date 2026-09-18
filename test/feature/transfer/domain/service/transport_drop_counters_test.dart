import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/transport_drop_counters.dart';

void main() {
  group('TransportDropCounters', () {
    test('totals accumulate across many windows without ever being read', () {
      final drops = TransportDropCounters();
      for (var i = 0; i < 10; i++) {
        drops.staleEpochDropped();
        drops.duplicateRouteDropped();
        drops.blocked();
      }
      expect(drops.staleEpochTotal, 10);
      expect(drops.duplicateRouteTotal, 10);
      expect(drops.blockedTotal, 10);
    });

    // The regression this class exists to prevent: issue #27 found the
    // diagnostic log line's 15s window reset silently zeroing the same totals
    // the link-quality grader diffs every 2s, producing invalid negative
    // deltas whenever the logger fired between two grader samples.
    test('taking the window never touches the cumulative totals', () {
      final drops = TransportDropCounters();
      drops.staleEpochDropped();
      drops.staleEpochDropped();
      drops.duplicateRouteDropped();
      drops.blocked();
      drops.blocked();
      drops.blocked();

      final window = drops.takeWindow();
      expect(window.staleEpoch, 2);
      expect(window.duplicateRoute, 1);
      expect(window.blocked, 3);

      // The totals must survive the window read intact.
      expect(drops.staleEpochTotal, 2);
      expect(drops.duplicateRouteTotal, 1);
      expect(drops.blockedTotal, 3);
    });

    test('taking the window zeroes only the window, repeatedly', () {
      final drops = TransportDropCounters();
      drops.staleEpochDropped();
      drops.takeWindow();
      // A quiet window in between reads as zero, not a carry-over of the
      // previous window's count.
      final quietWindow = drops.takeWindow();
      expect(quietWindow.staleEpoch, 0);
      // But the total from the first window is still there.
      expect(drops.staleEpochTotal, 1);

      drops.staleEpochDropped();
      final secondWindow = drops.takeWindow();
      expect(secondWindow.staleEpoch, 1);
      expect(drops.staleEpochTotal, 2);
    });

    test('reset zeroes both the window and the totals — the real session boundary', () {
      final drops = TransportDropCounters();
      drops.staleEpochDropped();
      drops.duplicateRouteDropped();
      drops.blocked();

      drops.reset();

      expect(drops.staleEpochTotal, 0);
      expect(drops.duplicateRouteTotal, 0);
      expect(drops.blockedTotal, 0);
      final window = drops.takeWindow();
      expect(window.staleEpoch, 0);
      expect(window.duplicateRoute, 0);
      expect(window.blocked, 0);
    });

    test('a fresh session after reset accumulates cleanly, unaffected by the prior session', () {
      final drops = TransportDropCounters();
      for (var i = 0; i < 50; i++) {
        drops.blocked();
      }
      drops.reset();
      drops.blocked();
      expect(drops.blockedTotal, 1);
    });
  });
}
