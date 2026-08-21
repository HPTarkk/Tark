import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/transport_stats.dart';
import 'package:tark/feature/transfer/domain/service/link_quality.dart';
import 'package:tark/feature/transfer/domain/service/transport_drop_counters.dart';

/// Regression coverage for issue #27: `WalkieTalkieCubit._gradeLink()` samples
/// [TransportStats] every 2s and diffs it against the previous sample,
/// assuming the counters are monotonic for the life of the session. The bug
/// was `WifiTransferRepositoryImpl._logSessionState()` zeroing those same
/// totals every ~15s for its own diagnostic log line, so a grader sample taken
/// just after the logger fired saw the totals drop — either producing a
/// negative delta, or worse, silently hiding real drops behind a reset that
/// happened to land between two ticks.
///
/// These tests exercise [TransportDropCounters] (what the totals are actually
/// sourced from now) through the same read/diff shape `_gradeLink` uses,
/// without needing the full cubit and its socket-backed dependencies.
void main() {
  const grader = LinkQualityGrader();

  TransportStats statsFrom(TransportDropCounters drops) => TransportStats(
    staleEpochDrops: drops.staleEpochTotal,
    duplicateRouteDrops: drops.duplicateRouteTotal,
    blockedSends: drops.blockedTotal,
  );

  LinkQuality gradeDelta(TransportStats now, TransportStats previous) =>
      grader.grade(
        LinkSignals(
          health: const ConnectionHealth.healthy(),
          staleEpochDrops: now.staleEpochDrops - previous.staleEpochDrops,
          duplicateRouteDrops:
              now.duplicateRouteDrops - previous.duplicateRouteDrops,
          blockedSends: now.blockedSends - previous.blockedSends,
        ),
      );

  group('grading across a diagnostic log window', () {
    test(
      'a steady drop rate still grades correctly even if the 15s log line '
      'fires between two 2s grader samples',
      () {
        final drops = TransportDropCounters();
        var previous = statsFrom(drops); // grader's baseline, TransportStats.none-equivalent

        // Six stale-epoch drops in this 2s tick — enough to move the grade
        // off excellent per the grader's own tolerance.
        for (var i = 0; i < 6; i++) {
          drops.staleEpochDropped();
        }
        final afterDrops = statsFrom(drops);
        expect(gradeDelta(afterDrops, previous), LinkQuality.good);
        previous = afterDrops;

        // The diagnostic log line fires here — takeWindow() must not perturb
        // the totals the grader just diffed against.
        drops.takeWindow();
        final afterLog = statsFrom(drops);

        // The bug: if takeWindow() had zeroed the totals (the old shared-field
        // behavior), this sample would show a large negative delta instead of
        // holding steady.
        expect(afterLog.staleEpochDrops, afterDrops.staleEpochDrops);
        expect(gradeDelta(afterLog, previous), LinkQuality.excellent);
        previous = afterLog;

        // A clean tick after the log line reports zero new drops, not a
        // spurious negative one.
        expect(gradeDelta(statsFrom(drops), previous), LinkQuality.excellent);
      },
    );

    test(
      'drops that straddle a log window still sum to the right cumulative total',
      () {
        final drops = TransportDropCounters();
        drops.blocked();
        drops.blocked();
        drops.takeWindow(); // log line: window taken, totals must survive
        drops.blocked();

        expect(drops.blockedTotal, 3);
      },
    );

    test('only an actual session reset produces a legitimate lower reading', () {
      final drops = TransportDropCounters();
      for (var i = 0; i < 10; i++) {
        drops.duplicateRouteDropped();
      }
      final endOfSession = statsFrom(drops);
      expect(endOfSession.duplicateRouteDrops, 10);

      // stopConnection()'s real boundary.
      drops.reset();
      final newSession = statsFrom(drops);
      expect(newSession.duplicateRouteDrops, 0);

      // A fresh WalkieTalkieCubit for the new session also starts its diff
      // baseline at TransportStats.none, so this is never diffed against the
      // old session's total in practice — but the repository's own counters
      // must independently agree with that fresh baseline.
      expect(gradeDelta(newSession, TransportStats.none), LinkQuality.excellent);
    });
  });
}
