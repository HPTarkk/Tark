import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/service/link_quality.dart';

void main() {
  const grader = LinkQualityGrader();

  LinkQuality grade({
    ConnectionHealth health = const ConnectionHealth.healthy(),
    bool sendFailing = false,
    bool unheardByPeers = false,
    bool unicastUnconfirmed = false,
    Duration? rtt,
    int staleEpochDrops = 0,
    int duplicateRouteDrops = 0,
    int blockedSends = 0,
    bool hasPeers = true,
  }) => grader.grade(
    LinkSignals(
      health: health,
      sendFailing: sendFailing,
      unheardByPeers: unheardByPeers,
      unicastUnconfirmed: unicastUnconfirmed,
      rtt: rtt,
      staleEpochDrops: staleEpochDrops,
      duplicateRouteDrops: duplicateRouteDrops,
      blockedSends: blockedSends,
      hasPeers: hasPeers,
    ),
  );

  group('LinkQualityGrader', () {
    test('a clean link with peers is excellent', () {
      expect(grade(), LinkQuality.excellent);
    });

    // The case the whole indicator exists for. Every local signal says fine —
    // packets arriving, socket bound, roster populated — and our voice is
    // reaching nobody.
    test('a peer saying it cannot hear us is weak, however clean the rest', () {
      expect(grade(unheardByPeers: true), LinkQuality.weak);
    });

    test('a failing send socket is weak', () {
      expect(grade(sendFailing: true), LinkQuality.weak);
    });

    // Stronger than unheardByPeers, and the reason the ping exists: that flag
    // arrives on presence, which reaches the peer over broadcast, so a peer
    // unreachable by unicast keeps confirming it hears us while none of our
    // audio lands. Only the unanswered ping catches it.
    test('a peer heard but not answering unicast is weak', () {
      expect(
        grade(unheardByPeers: false, unicastUnconfirmed: true),
        LinkQuality.weak,
      );
    });

    group('round trip', () {
      test('a fast LAN round trip is still excellent', () {
        expect(
          grade(rtt: const Duration(milliseconds: 12)),
          LinkQuality.excellent,
        );
      });

      test('a slow round trip drops the grade without calling it broken', () {
        expect(grade(rtt: const Duration(milliseconds: 400)), LinkQuality.good);
      });

      // Unmeasured is not slow. A channel in its first second has no reading,
      // and grading that would mark every session weak on entry.
      test('no reading is never graded as a slow one', () {
        expect(grade(rtt: null), LinkQuality.excellent);
      });
    });

    group('recovery outranks every measurement', () {
      test('including the quiet rung the banner stays silent for', () {
        expect(
          grade(health: const ConnectionHealth.degraded()),
          LinkQuality.recovering,
        );
      });

      test('and the louder rungs', () {
        for (final health in [
          const ConnectionHealth.reconnecting(),
          const ConnectionHealth.renegotiating(),
          const ConnectionHealth.down(),
        ]) {
          expect(
            grade(health: health),
            LinkQuality.recovering,
            reason: '${health.status}',
          );
        }
      });

      // Recovery wins over a would-be weak grade too: it is the more specific
      // statement, and the more useful one to act on.
      test('even when the send path is also failing', () {
        expect(
          grade(health: const ConnectionHealth.degraded(), sendFailing: true),
          LinkQuality.recovering,
        );
      });
    });

    group('drop tolerance', () {
      // Not zero on purpose: one straggler after a rejoin, or a duplicate as a
      // route repins, is the machinery working as designed.
      test('a handful of ghosts or duplicates is still excellent', () {
        expect(grade(staleEpochDrops: 5), LinkQuality.excellent);
        expect(grade(duplicateRouteDrops: 5), LinkQuality.excellent);
      });

      test('a steady stream of either drops the grade', () {
        expect(grade(staleEpochDrops: 6), LinkQuality.good);
        expect(grade(duplicateRouteDrops: 6), LinkQuality.good);
      });

      test('a backing-up send queue is weak', () {
        expect(grade(blockedSends: 20), LinkQuality.excellent);
        expect(grade(blockedSends: 21), LinkQuality.weak);
      });
    });

    // An empty channel is not a bad link; it is an empty channel. It gets its
    // own rung rather than a grade: excellent would be a claim about something
    // that has never carried a packet, weak would warn about a session with
    // nothing wrong with it — and `good`, which this used to return, told two
    // phones that had failed to find each other that they were connected.
    test('a solo channel reports alone, not a grade', () {
      expect(grade(hasPeers: false), LinkQuality.alone);
    });

    test('a solo channel still reports a broken send path', () {
      expect(grade(hasPeers: false, sendFailing: true), LinkQuality.weak);
    });

    // The worst signal wins rather than an average — letting a healthy
    // majority outvote one broken input is how a phone nobody can hear ends up
    // showing full bars.
    test('the worst signal wins', () {
      expect(
        grade(unheardByPeers: true, staleEpochDrops: 0, blockedSends: 0),
        LinkQuality.weak,
      );
    });
  });
}
