import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/adaptive_tier_gate.dart';

void main() {
  AdaptiveTierGate<String> gate({
    int downgradeEvidenceMs = 1000,
    int upgradeCleanMs = 3000,
    int minDwellMs = 500,
    int initialIndex = 0,
  }) => AdaptiveTierGate<String>(
    tiers: const ['low', 'mid', 'high'],
    downgradeEvidenceMs: downgradeEvidenceMs,
    upgradeCleanMs: upgradeCleanMs,
    minDwellMs: minDwellMs,
    initialIndex: initialIndex,
  );

  group('AdaptiveTierGate.advance', () {
    test('starts at initialIndex and stays put with no evidence', () {
      final g = gate(initialIndex: 1);
      expect(g.tier, 'mid');
      expect(g.tierIndex, 1);
      expect(
        g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: false,
          ceilingIndex: 2,
          elapsedMs: 100,
        ),
        isNull,
      );
      expect(g.tier, 'mid');
    });

    test('downgrades after sustained poor evidence clears minDwellMs', () {
      final g = gate(
        initialIndex: 1,
        downgradeEvidenceMs: 1000,
        minDwellMs: 500,
      );
      // 500ms in: dwell satisfied, but only 500ms of bad evidence banked.
      expect(
        g.advance(
          conditionsSupportCurrentTier: false,
          conditionsSupportNextTier: false,
          ceilingIndex: 2,
          elapsedMs: 500,
        ),
        isNull,
      );
      expect(g.tier, 'mid');
      // Another 500ms of bad evidence crosses downgradeEvidenceMs.
      final t = g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 500,
      );
      expect(t, isNotNull);
      expect(t!.from, 'mid');
      expect(t.to, 'low');
      expect(t.reason, contains('poor'));
      expect(g.tier, 'low');
    });

    test('bad evidence resets the moment conditions recover', () {
      final g = gate(initialIndex: 1, downgradeEvidenceMs: 1000);
      g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 900,
      );
      // One good tick resets the bad-evidence clock…
      g.advance(
        conditionsSupportCurrentTier: true,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 10,
      );
      // …so this does NOT push the total over downgradeEvidenceMs.
      final t = g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 900,
      );
      expect(t, isNull);
      expect(g.tier, 'mid');
    });

    test('cannot downgrade below the bottom tier', () {
      final g = gate(initialIndex: 0, downgradeEvidenceMs: 100, minDwellMs: 0);
      final t = g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 10000,
      );
      expect(t, isNull);
      expect(g.tier, 'low');
    });

    test('upgrades after sustained clean evidence clears minDwellMs', () {
      final g = gate(initialIndex: 0, upgradeCleanMs: 1000, minDwellMs: 500);
      expect(
        g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 2,
          elapsedMs: 999,
        ),
        isNull,
      );
      final t = g.advance(
        conditionsSupportCurrentTier: true,
        conditionsSupportNextTier: true,
        ceilingIndex: 2,
        elapsedMs: 1,
      );
      expect(t, isNotNull);
      expect(t!.from, 'low');
      expect(t.to, 'mid');
      expect(t.reason, contains('clean'));
    });

    test(
      'upgrade requires meeting the stricter next-tier bar, not just current-tier',
      () {
        final g = gate(initialIndex: 0, upgradeCleanMs: 500);
        final t = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: false,
          ceilingIndex: 2,
          elapsedMs: 10000,
        );
        expect(t, isNull);
        expect(g.tier, 'low');
      },
    );

    test('cannot upgrade past the top tier', () {
      final g = gate(initialIndex: 2, upgradeCleanMs: 100, minDwellMs: 0);
      final t = g.advance(
        conditionsSupportCurrentTier: true,
        conditionsSupportNextTier: true,
        ceilingIndex: 2,
        elapsedMs: 10000,
      );
      expect(t, isNull);
      expect(g.tier, 'high');
    });

    test(
      'a ceiling drop snaps down immediately, bypassing dwell and evidence',
      () {
        final g = gate(initialIndex: 2, minDwellMs: 999999);
        final t = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 0,
          elapsedMs: 1,
        );
        expect(t, isNotNull);
        expect(t!.from, 'high');
        expect(t.to, 'low');
        expect(t.reason, contains('ceiling'));
      },
    );

    test('a ceiling drop mid-hysteresis clears any banked evidence', () {
      final g = gate(initialIndex: 1, downgradeEvidenceMs: 1000, minDwellMs: 0);
      // Bank some (insufficient) bad evidence at 'mid'.
      g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 500,
      );
      // Ceiling drops all the way to 'low' — a hard fact, not a trend.
      g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 0,
        elapsedMs: 1,
      );
      expect(g.tier, 'low');
      // The stale bad-evidence banked at 'mid' must not still be sitting
      // there ready to fire a further (nonsensical, already-at-floor)
      // downgrade the instant a tiny bit more bad evidence arrives.
      final t = g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 0,
        elapsedMs: 501,
      );
      expect(t, isNull);
    });

    test('a ceiling rise does not itself cause an upgrade', () {
      final g = gate(initialIndex: 0, upgradeCleanMs: 100, minDwellMs: 0);
      final t = g.advance(
        conditionsSupportCurrentTier: true,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 1,
      );
      expect(t, isNull);
      expect(g.tier, 'low');
    });

    test(
      'clean evidence banked while pinned at the ceiling is not silently spent the instant the ceiling lifts',
      () {
        final g = gate(initialIndex: 0, upgradeCleanMs: 1000, minDwellMs: 0);
        // Pinned at the ceiling (0) for far longer than upgradeCleanMs, with
        // conditions that would otherwise qualify for an upgrade.
        g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 0,
          elapsedMs: 5000,
        );
        // Ceiling lifts. No upgrade should fire on this very tick — the clean
        // window has to be observed again now that there is somewhere to go.
        final t = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 2,
          elapsedMs: 1,
        );
        expect(t, isNull);
        expect(g.tier, 'low');
      },
    );

    test(
      'minDwellMs blocks a second transition immediately after the first',
      () {
        final g = gate(
          initialIndex: 1,
          downgradeEvidenceMs: 100,
          upgradeCleanMs: 100,
          minDwellMs: 1000,
        );
        final down = g.advance(
          conditionsSupportCurrentTier: false,
          conditionsSupportNextTier: false,
          ceilingIndex: 2,
          elapsedMs: 100,
        );
        expect(down, isNotNull);
        expect(g.tier, 'low');
        // Conditions flip clean immediately, and clean evidence alone would
        // qualify well before minDwellMs elapses — the dwell floor must still
        // hold the line.
        final up = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 2,
          elapsedMs: 100,
        );
        expect(up, isNull);
        expect(g.tier, 'low');
      },
    );

    test(
      'downgrade and upgrade windows can be tuned independently, downgrade faster',
      () {
        final g = gate(
          initialIndex: 1,
          downgradeEvidenceMs: 200,
          upgradeCleanMs: 5000,
          minDwellMs: 0,
        );
        final down = g.advance(
          conditionsSupportCurrentTier: false,
          conditionsSupportNextTier: false,
          ceilingIndex: 2,
          elapsedMs: 200,
        );
        expect(down, isNotNull);
        // Same elapsed time is nowhere near enough to earn the (much longer)
        // upgrade window back.
        final up = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 2,
          elapsedMs: 200,
        );
        expect(up, isNull);
      },
    );

    test(
      'reset snaps to the given index with no transition event and a fresh cooldown',
      () {
        final g = gate(initialIndex: 2, minDwellMs: 1000);
        g.reset(0);
        expect(g.tier, 'low');
        // Cooldown is already satisfied post-reset, same as at construction —
        // a session reset must not itself hold back a legitimate transition.
        final t = g.advance(
          conditionsSupportCurrentTier: true,
          conditionsSupportNextTier: true,
          ceilingIndex: 2,
          elapsedMs: 1,
        );
        expect(t, isNull); // no evidence banked yet, but not dwell-blocked
      },
    );

    test('reset clears banked evidence from before the reset', () {
      final g = gate(initialIndex: 1, downgradeEvidenceMs: 1000, minDwellMs: 0);
      g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 900,
      );
      g.reset(1);
      final t = g.advance(
        conditionsSupportCurrentTier: false,
        conditionsSupportNextTier: false,
        ceilingIndex: 2,
        elapsedMs: 100,
      );
      expect(t, isNull);
    });
  });
}
