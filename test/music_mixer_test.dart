import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/music_mixer.dart';

/// A mixer with the cushion and the ramps switched off, for the tests that are
/// about the mixing arithmetic itself. `fadeMs: 0` floors at a one-sample ramp,
/// which is unity — see the constructor.
MusicMixer bare({int maxQueuedSamples = 16000}) =>
    MusicMixer(maxQueuedSamples: maxQueuedSamples, prefillMs: 0, fadeMs: 0);

void main() {
  group('MusicMixer.mix', () {
    test('empty queue passes the voice frame through unchanged', () {
      expect(bare().mix([0.1, -0.2, 0.3], 1.0), [0.1, -0.2, 0.3]);
    });

    test('applies a cubic taper to the slider gain', () {
      final mixer = bare()..addChunk([1.0]);
      // slider 0.5 → gain 0.125
      expect(mixer.mix([0.0], 0.5).single, closeTo(0.125, 1e-9));
    });

    test('clamps the mixed sample to ±1', () {
      final mixer = bare()..addChunk([1.0]);
      expect(mixer.mix([0.9], 1.0).single, 1.0);
    });

    test('mixes only as many samples as are queued, rest passthrough', () {
      final mixer = bare()..addChunk([0.5]);
      expect(mixer.mix([0.0, 0.25], 1.0), [0.5, 0.25]);
    });

    test('consumes queued samples across calls', () {
      final mixer = bare()..addChunk([0.5, 0.25]);
      expect(mixer.mix([0.0], 1.0), [0.5]);
      expect(mixer.mix([0.0], 1.0), [0.25]);
      expect(mixer.mix([0.0], 1.0), [0.0]);
    });
  });

  group('MusicMixer prefill', () {
    // The bug this exists for: capture arrives in ~100 ms chunks and is drained
    // 20 ms at a time, so without a cushion the queue reaches zero just before
    // every chunk lands and the smallest delivery hiccup drops music out.
    test('withholds music until the cushion has filled', () {
      final mixer = MusicMixer(sampleRate: 1000, prefillMs: 10, fadeMs: 0);
      expect(mixer.prefillSamples, 10);

      mixer.addChunk(List.filled(6, 1.0));
      expect(mixer.isPriming, isTrue);
      // Voice only — the six queued samples stay banked rather than being
      // dribbled out as a fragment.
      expect(mixer.mix(List.filled(4, 0.0), 1.0), everyElement(0.0));
      expect(mixer.queuedSamples, 6);

      mixer.addChunk(List.filled(6, 1.0));
      expect(mixer.mix(List.filled(4, 0.0), 1.0), everyElement(1.0));
      expect(mixer.isPriming, isFalse);
    });

    test('re-primes after running dry, and counts it once', () {
      final mixer = MusicMixer(sampleRate: 1000, prefillMs: 2, fadeMs: 0)
        ..addChunk([1.0, 1.0]);

      expect(mixer.mix(List.filled(4, 0.0), 1.0), [1.0, 1.0, 0.0, 0.0]);
      expect(mixer.dropouts, 1);
      expect(mixer.isPriming, isTrue);

      // Still dry: already priming, so this is the same dropout, not a new one.
      mixer.mix(List.filled(4, 0.0), 1.0);
      expect(mixer.dropouts, 1);
    });

    test('clear returns the mixer to priming', () {
      final mixer = MusicMixer(sampleRate: 1000, prefillMs: 2, fadeMs: 0)
        ..addChunk([0.5, 0.5])
        ..clear();
      expect(mixer.isPriming, isTrue);
      expect(mixer.mix([0.0], 1.0), [0.0]);
      expect(mixer.queuedSamples, 0);
    });
  });

  group('MusicMixer ramps', () {
    test('ramps music in over the fade at a start', () {
      final mixer = MusicMixer(sampleRate: 1000, prefillMs: 0, fadeMs: 4)
        ..addChunk(List.filled(6, 1.0));
      final out = mixer.mix(List.filled(6, 0.0), 1.0);
      expect(out.take(4), [
        closeTo(0.25, 1e-9),
        closeTo(0.50, 1e-9),
        closeTo(0.75, 1e-9),
        closeTo(1.00, 1e-9),
      ]);
      expect(out.skip(4), everyElement(closeTo(1.0, 1e-9)));
    });

    test('ramps music out over the tail when the queue runs dry', () {
      final mixer = MusicMixer(sampleRate: 1000, prefillMs: 0, fadeMs: 3)
        ..addChunk(List.filled(5, 1.0));
      final out = mixer.mix(List.filled(8, 0.0), 1.0);
      // Ramp in over the first three, then back down across the last three
      // rather than stepping straight from full level to silence.
      expect(out.sublist(0, 5), [
        closeTo(1 / 3, 1e-9),
        closeTo(2 / 3, 1e-9),
        closeTo(1.0, 1e-9),
        closeTo(2 / 3, 1e-9),
        closeTo(1 / 3, 1e-9),
      ]);
      expect(out.sublist(5), everyElement(0.0));
    });
  });

  group('MusicMixer drift', () {
    test('trims back toward the prefill above the high-water mark', () {
      final mixer = MusicMixer(
        sampleRate: 1000,
        prefillMs: 10,
        highWaterMs: 30,
        fadeMs: 0,
      )..addChunk(List.filled(50, 1.0));

      // 50 queued, over the 30 high-water: one 10-sample step comes off before
      // the 5 consumed by this frame.
      mixer.mix(List.filled(5, 0.0), 1.0);
      expect(mixer.trims, 1);
      expect(mixer.queuedSamples, 35);

      mixer.mix(List.filled(5, 0.0), 1.0);
      expect(mixer.trims, 2);
      expect(mixer.queuedSamples, 20);

      // Back under the mark — no further trimming, just the frame's own drain.
      mixer.mix(List.filled(5, 0.0), 1.0);
      expect(mixer.trims, 2);
      expect(mixer.queuedSamples, 15);
    });

    test('never trims below the prefill', () {
      final mixer = MusicMixer(
        sampleRate: 1000,
        prefillMs: 10,
        highWaterMs: 12,
        fadeMs: 0,
      )..addChunk(List.filled(15, 1.0));

      // Excess over the prefill is 5, less than the 10-sample step, so the trim
      // stops at the cushion instead of overshooting into a dropout.
      mixer.mix(List.filled(2, 0.0), 1.0);
      expect(mixer.queuedSamples, 8);
      expect(mixer.dropouts, 0);
    });
  });

  group('MusicMixer queue cap', () {
    test('drops the oldest samples over maxQueuedSamples', () {
      final mixer = bare(maxQueuedSamples: 2)..addChunk([0.1, 0.2, 0.3]);
      expect(mixer.mix([0.0, 0.0], 1.0), [0.2, 0.3]);
      expect(mixer.overflowDrops, 1);
    });

    test('clear empties the queue', () {
      final mixer = bare()
        ..addChunk([0.5])
        ..clear();
      expect(mixer.mix([0.0], 1.0), [0.0]);
    });
  });

  group('MusicMixer backlog', () {
    // Both sides of this queue live on the UI isolate, so backgrounding the app
    // stalls capture delivery and the drain together; on resume the buffered
    // chunks land at once. Walking that down in 10 ms steps is what produced
    // bursts of 25-48 trims per 2 s in the logs from a Galaxy A53, each one an
    // audible seam.
    MusicMixer real() => MusicMixer(sampleRate: 1000, prefillMs: 200);

    test('a backlog is dropped in one splice, not walked down', () {
      final mixer = real();
      // 1.5 s at 1 kHz — past floodSamples (900 ms), so not drift.
      mixer.addChunk(List<double>.filled(1500, 0.5));

      mixer.mix(List<double>.filled(20, 0.0), 1.0);

      expect(mixer.floods, 1);
      expect(
        mixer.trims,
        0,
        reason: 'a backlog must not be charged to the drift path',
      );
      expect(
        mixer.queuedSamples,
        lessThanOrEqualTo(mixer.prefillSamples),
        reason: 'one splice must land back at the cushion, not near the cap',
      );
    });

    test('ordinary drift is still walked down in steps', () {
      final mixer = real();
      // Just over the high-water mark (450 ms) but well under the flood
      // threshold: this is the clock drift the stepped trim exists for.
      mixer.addChunk(List<double>.filled(500, 0.5));

      mixer.mix(List<double>.filled(20, 0.0), 1.0);

      expect(mixer.floods, 0);
      expect(mixer.trims, 1);
      expect(
        mixer.queuedSamples,
        greaterThan(mixer.prefillSamples),
        reason: 'drift is corrected a step at a time, not snapped back',
      );
    });
  });

  group('MusicMixer.levelOf', () {
    test('empty chunk is 0', () {
      expect(MusicMixer.levelOf([]), 0);
    });

    test('computes RMS', () {
      expect(MusicMixer.levelOf([0.5, -0.5]), closeTo(0.5, 1e-9));
    });
  });
}
