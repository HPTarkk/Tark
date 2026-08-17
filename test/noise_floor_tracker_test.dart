import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/noise_floor_tracker.dart';

void main() {
  /// Feeds [rms] for [frames] frames, the way a steady background would.
  void soak(NoiseFloorTracker tracker, double rms, int frames) {
    for (var i = 0; i < frames; i++) {
      tracker.observe(rms);
    }
  }

  group('NoiseFloorTracker', () {
    test('has no opinion before it has heard anything', () {
      expect(NoiseFloorTracker().noiseFloor, isNull);
    });

    // Creeping up from zero would leave the floor far too low for the first
    // several seconds of every session — exactly when someone is checking
    // whether the channel works at all.
    test('adopts the first frame rather than creeping up from zero', () {
      final tracker = NoiseFloorTracker();
      tracker.observe(0.04);
      expect(tracker.noiseFloor, 0.04);
    });

    test('settles onto a steady background', () {
      final tracker = NoiseFloorTracker();
      tracker.observe(0.05);
      soak(tracker, 0.01, 200);
      expect(tracker.noiseFloor, closeTo(0.01, 0.001));
    });

    test('follows the background down quickly', () {
      final tracker = NoiseFloorTracker();
      soak(tracker, 0.06, 50);
      // Ten frames is 200 ms.
      soak(tracker, 0.01, 10);
      expect(tracker.noiseFloor, lessThan(0.02));
    });

    group('speech', () {
      // The failure this guard exists for: hundreds of consecutive loud frames
      // creeping the estimate up toward speech level, raising the threshold
      // until the gate closes on the speaker's own voice mid-sentence.
      test('a long sentence does not drag the floor up behind it', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.01, 100);
        final quiet = tracker.noiseFloor!;

        // Five seconds of continuous speech at 20 ms frames.
        soak(tracker, 0.3, 250);

        expect(tracker.noiseFloor, quiet);
      });

      test('background noise still moves it, unlike speech', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.01, 100);
        final quiet = tracker.noiseFloor!;

        // Just under the speech ratio: louder background, not a voice.
        soak(tracker, 0.025, 500);

        expect(tracker.noiseFloor, greaterThan(quiet));
      });
    });

    group('threshold', () {
      // The slider's promise at 0 % is that nothing the mic hands over is ever
      // withheld. No amount of measured background may override that, or the
      // "VOX off" setting would silently start gating.
      test('zero stays zero, however loud the background', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.5, 100);
        expect(tracker.thresholdFor(0.0), 0.0);
      });

      test('a quiet room leaves the user\'s setting alone', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.001, 200);
        expect(tracker.thresholdFor(0.02), 0.02);
      });

      // The highway case: wind noise well above the user's static threshold
      // would hold the channel open permanently.
      test('a loud background raises the bar above the setting', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.05, 200);
        expect(tracker.thresholdFor(0.02), greaterThan(0.02));
      });

      // The slider is a statement about what the user does not want
      // transmitted, so a measured background may raise the bar but never
      // lower it past their own floor.
      test('never returns less than the user asked for', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.0001, 200);
        expect(tracker.thresholdFor(0.08), 0.08);
      });

      // A mic fault reporting an enormous level must not be able to set a
      // threshold no voice could cross — that is a silently muted phone.
      test('a broken mic cannot mute the phone', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 5.0, 200);
        expect(tracker.thresholdFor(0.02), lessThanOrEqualTo(0.15));
      });

      test('before any frame the setting is used unchanged', () {
        expect(NoiseFloorTracker().thresholdFor(0.03), 0.03);
      });
    });

    test('a reset forgets the route it was measuring', () {
      final tracker = NoiseFloorTracker();
      soak(tracker, 0.05, 100);
      tracker.reset();
      expect(tracker.noiseFloor, isNull);
      expect(tracker.thresholdFor(0.02), 0.02);
    });

    test('a nonsense level is ignored rather than poisoning the estimate', () {
      final tracker = NoiseFloorTracker();
      soak(tracker, 0.02, 50);
      final before = tracker.noiseFloor;
      tracker.observe(double.nan);
      tracker.observe(-1.0);
      expect(tracker.noiseFloor, before);
    });
  });
}
