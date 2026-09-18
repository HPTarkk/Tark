import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/settings/vox_margin.dart';
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
        expect(tracker.thresholdFor(VoxMargin.off), 0.0);
      });

      // The whole point of the reframe: one setting, two rooms, two levels.
      // The old absolute slider gave the same number in both, and so was wrong
      // in at least one of them.
      test('the same setting means a different level in a different room', () {
        final quiet = NoiseFloorTracker();
        soak(quiet, 0.002, 200);
        final loud = NoiseFloorTracker();
        soak(loud, 0.03, 200);

        expect(loud.thresholdFor(0.5), greaterThan(quiet.thresholdFor(0.5)));
      });

      test('the level sits the requested distance above the background', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.02, 400);
        final floor = tracker.noiseFloor!;

        expect(
          tracker.thresholdFor(0.5),
          closeTo(floor * VoxMargin.multiplierFor(0.5), floor * 0.05),
        );
      });

      test('a bigger margin asks for more', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 0.01, 200);
        expect(tracker.thresholdFor(1.0), greaterThan(tracker.thresholdFor(0.2)));
      });

      // The hazard a pure margin introduces and _minFloor exists to stop: the
      // platform noise suppressor on some phones hands back exact digital
      // silence between words, which would drag the floor to zero and
      // disarm the gate by multiplication. See VoxGate's field report.
      group('a mic that reports digital silence', () {
        test('cannot disarm the gate', () {
          final tracker = NoiseFloorTracker();
          soak(tracker, 0.01, 50);
          soak(tracker, 0.0, 200); // the suppressor doing "its job"

          expect(tracker.thresholdFor(0.5), greaterThan(0.0));
        });

        test('still leaves a level a speaking voice clears easily', () {
          final tracker = NoiseFloorTracker();
          soak(tracker, 0.0, 200);
          // Conversational speech sits an order of magnitude above this.
          expect(tracker.thresholdFor(1.0), lessThan(0.05));
        });
      });

      // A mic fault reporting an enormous level must not be able to set a
      // threshold no voice could cross — that is a silently muted phone.
      test('a broken mic cannot mute the phone', () {
        final tracker = NoiseFloorTracker();
        soak(tracker, 5.0, 200);
        expect(tracker.thresholdFor(1.0), lessThanOrEqualTo(0.15));
      });

      // Failing open: the cost of guessing high before the first frame is a
      // clipped word, and the cost of guessing wrong for longer is a phone
      // that is quietly mute.
      test('before any frame the gate is open', () {
        expect(NoiseFloorTracker().thresholdFor(0.5), 0.0);
      });
    });

    test('a reset forgets the route it was measuring', () {
      final tracker = NoiseFloorTracker();
      soak(tracker, 0.05, 100);
      tracker.reset();
      expect(tracker.noiseFloor, isNull);
      expect(tracker.thresholdFor(0.5), 0.0);
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
