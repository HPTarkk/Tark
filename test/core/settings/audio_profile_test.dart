import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/settings/app_settings.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/core/settings/noise_suppression_engine.dart';

AudioProfile resolve({
  required bool riding,
  double vox = 0.0,
  double noise = 1.0,
  NoiseSuppressionEngine engine = NoiseSuppressionEngine.spectral,
  int buffer = 100,
}) => AudioProfile.resolve(
  ridingPreset: riding,
  voxMargin: vox,
  noiseSuppression: noise,
  noiseSuppressionEngine: engine,
  targetBufferMs: buffer,
);

void main() {
  group('preset off', () {
    test('passes every stored value through untouched', () {
      final p = resolve(
        riding: false,
        vox: 0.07,
        noise: 0.3,
        engine: NoiseSuppressionEngine.both,
        buffer: 220,
      );
      expect(p.voxMargin, 0.07);
      expect(p.noiseSuppression, 0.3);
      expect(p.noiseSuppressionEngine, NoiseSuppressionEngine.both);
      expect(p.targetBufferMs, 220);
      expect(p.fromPreset, isFalse);
    });

    test('playback gain is unity, so the RX path stays a no-op', () {
      expect(resolve(riding: false).playbackGain, 1.0);
    });

    test('preserves "0 means VOX off" — nothing may arm the gate but the user', () {
      expect(resolve(riding: false, vox: 0.0).voxMargin, 0.0);
    });
  });

  group('preset on', () {
    test('overrides every knob regardless of what was stored', () {
      final p = resolve(
        riding: true,
        vox: 0.13,
        noise: 0.0,
        engine: NoiseSuppressionEngine.off,
        buffer: 60,
      );
      expect(p, RidingPreset.profile);
      expect(p.fromPreset, isTrue);
    });

    test('arms the VOX gate, which a default install leaves off', () {
      // The whole point of the preset: at the shipped default of 0 the
      // adaptive noise-floor tracking never runs, because there is no gate for
      // it to move. Anything > 0 hands NoiseFloorTracker something to raise.
      expect(AppSettings.defaults().voxMargin, 0.0);
      expect(RidingPreset.voxMargin, greaterThan(0.0));
    });

    test('states a real margin instead of tiptoeing around the tracker', () {
      // The old value was tiny on purpose: on the absolute scale, anything
      // higher would have out-shouted the tracker's fixed 2.5x and clipped
      // word onsets indoors, so the preset could only arm the gate and then
      // get out of the way. A margin cannot out-shout the tracker — it *is*
      // the tracker's setting — so the preset finally gets to choose one, and
      // it chooses more separation than the middle of the slider.
      expect(RidingPreset.voxMargin, greaterThanOrEqualTo(0.5));
      expect(RidingPreset.voxMargin, lessThan(1.0));
    });

    test('does not over-suppress: moderate strength, never cascaded', () {
      // Two cleaners in series is the over-suppression trap, and full strength
      // eats the consonants that carry a word through a helmet.
      expect(RidingPreset.engine, NoiseSuppressionEngine.rnnoise);
      expect(RidingPreset.engine, isNot(NoiseSuppressionEngine.both));
      expect(RidingPreset.noiseSuppression, lessThan(1.0));
      expect(RidingPreset.noiseSuppression, greaterThan(0.0));
    });

    test('anchors the jitter buffer deeper than the default', () {
      expect(
        RidingPreset.targetBufferMs,
        greaterThan(AppSettings.defaults().targetBufferMs),
      );
    });

    test('raises playback gain, but only slightly', () {
      // Loud-and-distorted is less intelligible than quiet-and-clean; a large
      // boost would sit against the limiter through every sentence.
      expect(RidingPreset.playbackGain, greaterThan(1.0));
      expect(RidingPreset.playbackGain, lessThanOrEqualTo(1.5));
    });
  });

  test('the preset is an override, never a write — off restores exactly', () {
    // Resolving with the preset on and then off must return the original
    // stored values, since resolve() is the only thing that ever combines
    // them. This is what makes the switch safe to try mid-ride.
    const stored = (vox: 0.09, noise: 0.42, buffer: 175);
    final off = resolve(
      riding: false,
      vox: stored.vox,
      noise: stored.noise,
      buffer: stored.buffer,
    );
    resolve(
      riding: true,
      vox: stored.vox,
      noise: stored.noise,
      buffer: stored.buffer,
    );
    final backOff = resolve(
      riding: false,
      vox: stored.vox,
      noise: stored.noise,
      buffer: stored.buffer,
    );
    expect(backOff, off);
  });

  test('defaults ship with the preset off', () {
    // On by default would gate the mic at a desk, where everything the mic
    // hears is worth sending.
    expect(AppSettings.defaults().ridingPreset, isFalse);
  });
}
