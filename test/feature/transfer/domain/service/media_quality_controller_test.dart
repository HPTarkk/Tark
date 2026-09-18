import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/media_quality_controller.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';

void main() {
  group('MediaQualityController.advance', () {
    test('starts active', () {
      final c = MediaQualityController();
      expect(c.tier, MediaSendTier.active);
      expect(c.shouldSend, isTrue);
    });

    test('sustained loss past the failing bar suspends transmission', () {
      final c = MediaQualityController(
        downgradeEvidenceMs: 1000,
        minDwellMs: 0,
      );
      const failing = AudioLinkConditions(lossFraction: 0.30);
      c.advance(conditions: failing, elapsedMs: 999);
      expect(c.tier, MediaSendTier.active);
      final t = c.advance(conditions: failing, elapsedMs: 1);
      expect(t, isNotNull);
      expect(t!.to, MediaSendTier.suspended);
      expect(c.shouldSend, isFalse);
    });

    test(
      'loss at MediaOpusTuner\'s own worst tier does not suspend — that tier is still "active"',
      () {
        final c = MediaQualityController(
          downgradeEvidenceMs: 100,
          minDwellMs: 0,
        );
        // 20% loss: MediaOpusTuner's worst bitrate tier (32 kbps), but below
        // maxLossPerc (25) — still a supported operating point, not a reason
        // to suspend.
        const worstTierStillOperating = AudioLinkConditions(lossFraction: 0.20);
        final t = c.advance(
          conditions: worstTierStillOperating,
          elapsedMs: 999999,
        );
        expect(t, isNull);
        expect(c.tier, MediaSendTier.active);
      },
    );

    test('congestion alone does not suspend an active stream', () {
      final c = MediaQualityController(downgradeEvidenceMs: 100, minDwellMs: 0);
      const congestedNoLoss = AudioLinkConditions(
        lossFraction: 0.0,
        rtt: Duration(milliseconds: 500),
      );
      final t = c.advance(conditions: congestedNoLoss, elapsedMs: 999999);
      expect(t, isNull);
      expect(c.tier, MediaSendTier.active);
    });

    test('a clean, uncongested link resumes a suspended stream', () {
      final c = MediaQualityController(
        downgradeEvidenceMs: 100,
        upgradeCleanMs: 1000,
        minDwellMs: 0,
      );
      const failing = AudioLinkConditions(lossFraction: 0.30);
      c.advance(conditions: failing, elapsedMs: 100);
      expect(c.tier, MediaSendTier.suspended);

      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(conditions: clean, elapsedMs: 999);
      expect(c.tier, MediaSendTier.suspended);
      final t = c.advance(conditions: clean, elapsedMs: 1);
      expect(t, isNotNull);
      expect(t!.to, MediaSendTier.active);
      expect(c.shouldSend, isTrue);
    });

    test(
      'a congested link stays suspended even with zero loss — resume requires an uncongested link',
      () {
        final c = MediaQualityController(
          downgradeEvidenceMs: 100,
          upgradeCleanMs: 100,
          minDwellMs: 0,
        );
        const failing = AudioLinkConditions(lossFraction: 0.30);
        c.advance(conditions: failing, elapsedMs: 100);
        expect(c.tier, MediaSendTier.suspended);

        const congestedNoLoss = AudioLinkConditions(
          lossFraction: 0.0,
          rtt: Duration(milliseconds: 500),
        );
        final t = c.advance(conditions: congestedNoLoss, elapsedMs: 100000);
        expect(t, isNull);
        expect(c.tier, MediaSendTier.suspended);
      },
    );

    test(
      'moderate loss below the resume bar does not resume a suspended stream',
      () {
        final c = MediaQualityController(
          downgradeEvidenceMs: 100,
          upgradeCleanMs: 100,
          minDwellMs: 0,
        );
        const failing = AudioLinkConditions(lossFraction: 0.30);
        c.advance(conditions: failing, elapsedMs: 100);
        expect(c.tier, MediaSendTier.suspended);

        // 10% loss: better than failing, but still above the stricter resume
        // bar (8%).
        const moderate = AudioLinkConditions(lossFraction: 0.10);
        final t = c.advance(conditions: moderate, elapsedMs: 100000);
        expect(t, isNull);
        expect(c.tier, MediaSendTier.suspended);
      },
    );

    test('bad evidence resets the moment conditions recover', () {
      final c = MediaQualityController(
        downgradeEvidenceMs: 1000,
        minDwellMs: 0,
      );
      const failing = AudioLinkConditions(lossFraction: 0.30);
      c.advance(conditions: failing, elapsedMs: 900);
      expect(c.tier, MediaSendTier.active);

      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(conditions: clean, elapsedMs: 10);

      final t = c.advance(conditions: failing, elapsedMs: 900);
      expect(t, isNull);
      expect(c.tier, MediaSendTier.active);
    });

    test('reset returns to active with no lingering evidence', () {
      final c = MediaQualityController(
        downgradeEvidenceMs: 1000,
        minDwellMs: 0,
      );
      const failing = AudioLinkConditions(lossFraction: 0.30);
      c.advance(conditions: failing, elapsedMs: 999999);
      expect(c.tier, MediaSendTier.suspended);

      c.reset();
      expect(c.tier, MediaSendTier.active);
      expect(c.shouldSend, isTrue);
    });
  });
}
