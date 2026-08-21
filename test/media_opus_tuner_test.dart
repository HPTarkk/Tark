import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/transfer/domain/service/media_opus_tuner.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';

void main() {
  const tuner = MediaOpusTuner();

  group('MediaOpusTuner', () {
    test('a clean link gets the top bitrate and budgets no redundancy', () {
      final tuning = tuner.tune(const AudioLinkConditions());
      expect(tuning.bitrate, 96000);
      expect(tuning.packetLossPerc, 0);
    });

    test('an unmeasured link starts conservative, not optimistic', () {
      // Unlike voice (OpusTuner.initial), media only ever starts once a
      // channel already exists and the link has already been measured, so
      // there is no "most links are actually fine" assumption to lean on.
      expect(MediaOpusTuner.initial.bitrate, lessThan(96000));
      expect(MediaOpusTuner.initial.packetLossPerc, 0);
    });

    test('measured loss becomes the redundancy budget', () {
      expect(
        tuner
            .tune(const AudioLinkConditions(lossFraction: 0.05))
            .packetLossPerc,
        5,
      );
      expect(
        tuner
            .tune(const AudioLinkConditions(lossFraction: 0.12))
            .packetLossPerc,
        12,
      );
    });

    test('the redundancy budget is capped, same ceiling as voice', () {
      final tuning = tuner.tune(const AudioLinkConditions(lossFraction: 0.8));
      expect(tuning.packetLossPerc, MediaOpusTuner.maxLossPerc);
      expect(MediaOpusTuner.maxLossPerc, OpusTuner.maxLossPerc);
    });

    test('bitrate and complexity fall as loss rises', () {
      final clean = tuner.tune(const AudioLinkConditions(lossFraction: 0.0));
      final light = tuner.tune(const AudioLinkConditions(lossFraction: 0.05));
      final heavy = tuner.tune(const AudioLinkConditions(lossFraction: 0.12));
      final severe = tuner.tune(const AudioLinkConditions(lossFraction: 0.3));

      expect(clean.bitrate, greaterThan(light.bitrate));
      expect(light.bitrate, greaterThan(heavy.bitrate));
      expect(heavy.bitrate, greaterThan(severe.bitrate));
      expect(clean.complexity, greaterThan(severe.complexity));
    });

    test('a congested link is backed off before it starts losing', () {
      const congested = AudioLinkConditions(
        lossFraction: 0.0,
        rtt: Duration(milliseconds: 400),
      );
      final tuning = tuner.tune(congested);
      expect(tuning.bitrate, lessThan(96000));
      expect(tuning.packetLossPerc, 0);
    });

    test(
      'identical conditions produce an equal tuning, so nothing is re-applied',
      () {
        const conditions = AudioLinkConditions(lossFraction: 0.05);
        expect(tuner.tune(conditions), tuner.tune(conditions));
      },
    );

    // The floor exists so a caller can tell "still HD" from "degraded" —
    // required by #29's acceptance criteria that low tiers never claim HD.
    test('every reachable bitrate at or above light loss meets the HD floor', () {
      for (final loss in [0.0, 0.01, 0.05, 0.07]) {
        final tuning = tuner.tune(AudioLinkConditions(lossFraction: loss));
        expect(
          tuning.bitrate,
          greaterThanOrEqualTo(MediaOpusTuner.hdFloorBitrate),
          reason: 'loss=$loss',
        );
      }
    });

    test('heavy loss falls below the HD floor rather than pretending', () {
      final tuning = tuner.tune(const AudioLinkConditions(lossFraction: 0.3));
      expect(tuning.bitrate, lessThan(MediaOpusTuner.hdFloorBitrate));
    });
  });

  group('MediaOpusTuner.forProfile', () {
    test('a media profile is accepted', () {
      expect(
        () => MediaOpusTuner.forProfile(AudioFormatProfile.media48kStereo),
        returnsNormally,
      );
      expect(
        () => MediaOpusTuner.forProfile(AudioFormatProfile.media48kMono),
        returnsNormally,
      );
    });

    test('a voice profile is rejected', () {
      expect(
        () => MediaOpusTuner.forProfile(AudioFormatProfile.legacy16k),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
