import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/domain/service/opus_tuner.dart';

void main() {
  const tuner = OpusTuner();

  group('OpusTuner', () {
    test('a clean link gets the top bitrate and budgets no redundancy', () {
      final tuning = tuner.tune(const AudioLinkConditions());
      expect(tuning.bitrate, 24000);
      expect(tuning.packetLossPerc, 0);
    });

    // An unmeasured link is most often a reliable one — Bluetooth RFCOMM is
    // ordered and lossless, and neither it nor the guest link runs the unicast
    // ping that produces a measurement. Budgeting redundancy there would spend
    // bitrate defending against loss that cannot happen.
    test('an unmeasured link budgets no redundancy', () {
      expect(OpusTuner.initial.packetLossPerc, 0);
      expect(tuner.tune(AudioLinkConditions.unknown).packetLossPerc, 0);
    });

    test('measured loss becomes the redundancy budget', () {
      expect(tuner.tune(const AudioLinkConditions(lossFraction: 0.05)).packetLossPerc, 5);
      expect(tuner.tune(const AudioLinkConditions(lossFraction: 0.12)).packetLossPerc, 12);
    });

    // Past this, libopus spends so much of the frame on the FEC copy that the
    // primary encoding audibly suffers — and a link losing this much is a job
    // for the recovery ladder, not the codec.
    test('the redundancy budget is capped', () {
      final tuning = tuner.tune(const AudioLinkConditions(lossFraction: 0.8));
      expect(tuning.packetLossPerc, OpusTuner.maxLossPerc);
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

    // A queue this deep is about to become loss. Backing the bitrate off before
    // it does is the one thing the encoder can contribute.
    test('a congested link is backed off before it starts losing', () {
      const congested = AudioLinkConditions(
        lossFraction: 0.0,
        rtt: Duration(milliseconds: 400),
      );
      final tuning = tuner.tune(congested);
      expect(tuning.bitrate, lessThan(24000));
      // Still no loss to defend against, so no bits are spent on redundancy.
      expect(tuning.packetLossPerc, 0);
    });

    // An unanswered ping is already covered by unicastUnconfirmed; treating "no
    // reading" as "slow" would back every channel off for its first second.
    test('an unmeasured round trip is not treated as a slow one', () {
      final tuning = tuner.tune(const AudioLinkConditions(lossFraction: 0.0));
      expect(tuning.bitrate, 24000);
    });

    test('identical conditions produce an equal tuning, so nothing is re-applied', () {
      const conditions = AudioLinkConditions(lossFraction: 0.05);
      expect(tuner.tune(conditions), tuner.tune(conditions));
    });
  });
}
