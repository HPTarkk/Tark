import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/voice_quality_controller.dart';

void main() {
  group('VoiceQualityController.advance', () {
    test('starts at legacy16k', () {
      final c = VoiceQualityController();
      expect(c.profile, AudioFormatProfile.legacy16k);
    });

    test('a clean, uncongested link with an HD ceiling upgrades to hd24k', () {
      final c = VoiceQualityController(upgradeCleanMs: 1000, minDwellMs: 0);
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999,
      );
      expect(c.profile, AudioFormatProfile.legacy16k);
      final t = c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 1,
      );
      expect(t, isNotNull);
      expect(t!.to, AudioFormatProfile.hd24k);
      expect(c.profile, AudioFormatProfile.hd24k);
    });

    test('cannot reach hd24k while the peer ceiling is legacy16k', () {
      final c = VoiceQualityController(upgradeCleanMs: 100, minDwellMs: 0);
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.legacy16k,
        elapsedMs: 100000,
      );
      expect(c.profile, AudioFormatProfile.legacy16k);
    });

    test('sustained heavy loss falls back to legacy16k from hd24k', () {
      final c = VoiceQualityController(
        downgradeEvidenceMs: 1000,
        minDwellMs: 0,
      );
      // Force it up to HD first.
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999999,
      );
      expect(c.profile, AudioFormatProfile.hd24k);

      const poor = AudioLinkConditions(lossFraction: 0.20);
      final t = c.advance(
        conditions: poor,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 1000,
      );
      expect(t, isNotNull);
      expect(t!.to, AudioFormatProfile.legacy16k);
    });

    test(
      'a congested but low-loss link is treated as not-clean-enough to upgrade',
      () {
        final c = VoiceQualityController(upgradeCleanMs: 100, minDwellMs: 0);
        const congested = AudioLinkConditions(
          lossFraction: 0.0,
          rtt: Duration(milliseconds: 500),
        );
        c.advance(
          conditions: congested,
          ceiling: AudioFormatProfile.hd24k,
          elapsedMs: 100000,
        );
        expect(c.profile, AudioFormatProfile.legacy16k);
      },
    );

    test('a congested link at hd24k is downgraded even with zero loss', () {
      final c = VoiceQualityController(downgradeEvidenceMs: 100, minDwellMs: 0);
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999999,
      );
      expect(c.profile, AudioFormatProfile.hd24k);

      const congested = AudioLinkConditions(
        lossFraction: 0.0,
        rtt: Duration(milliseconds: 500),
      );
      final t = c.advance(
        conditions: congested,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 100,
      );
      expect(t, isNotNull);
      expect(t!.to, AudioFormatProfile.legacy16k);
    });

    test('moderate loss holds hd24k rather than falling back', () {
      final c = VoiceQualityController(downgradeEvidenceMs: 100, minDwellMs: 0);
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999999,
      );
      expect(c.profile, AudioFormatProfile.hd24k);

      // 5% loss: below the "poor" bar, well above the "clean" bar.
      const moderate = AudioLinkConditions(lossFraction: 0.05);
      final t = c.advance(
        conditions: moderate,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 100000,
      );
      expect(t, isNull);
      expect(c.profile, AudioFormatProfile.hd24k);
    });

    test('a peer roster losing HD support drops the ceiling immediately', () {
      final c = VoiceQualityController(minDwellMs: 999999);
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999999,
      );
      expect(c.profile, AudioFormatProfile.hd24k);

      // A peer without HD just joined — ceiling drops to legacy16k. Must
      // not wait out minDwellMs, which is deliberately huge in this test.
      final t = c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.legacy16k,
        elapsedMs: 1,
      );
      expect(t, isNotNull);
      expect(t!.to, AudioFormatProfile.legacy16k);
    });

    test('reset returns to legacy16k with no lingering evidence', () {
      final c = VoiceQualityController(
        downgradeEvidenceMs: 1000,
        minDwellMs: 0,
      );
      const clean = AudioLinkConditions(lossFraction: 0.0);
      c.advance(
        conditions: clean,
        ceiling: AudioFormatProfile.hd24k,
        elapsedMs: 999999,
      );
      expect(c.profile, AudioFormatProfile.hd24k);

      c.reset();
      expect(c.profile, AudioFormatProfile.legacy16k);
    });
  });
}
