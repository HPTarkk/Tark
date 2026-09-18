import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/settings/app_settings.dart';
import 'package:tark/core/settings/audio_profile.dart';
import 'package:tark/core/settings/noise_suppression_engine.dart';
import 'package:tark/core/settings/suppression_plan.dart';

SuppressionPlan plan(
  NoiseSuppressionEngine engine, {
  double strength = 1.0,
  bool rnnoiseAvailable = true,
}) => SuppressionPlan.resolve(
  engine: engine,
  strength: strength,
  rnnoiseAvailable: rnnoiseAvailable,
);

void main() {
  group('which stages run', () {
    test('off cleans with nothing at all', () {
      final p = plan(NoiseSuppressionEngine.off);
      expect(p.useRnnoise, isFalse);
      expect(p.useSpectral, isFalse);
    });

    test('off stays off even with the native denoiser available', () {
      // The one choice that degrades to nothing rather than to the other
      // cleaner: asking for no cleaning is not asking for a different cleaner.
      expect(plan(NoiseSuppressionEngine.off).useSpectral, isFalse);
    });

    test('rnnoise and both fall back to spectral when unavailable', () {
      for (final e in [
        NoiseSuppressionEngine.rnnoise,
        NoiseSuppressionEngine.both,
      ]) {
        final p = plan(e, rnnoiseAvailable: false);
        expect(p.useRnnoise, isFalse, reason: '$e');
        expect(p.useSpectral, isTrue, reason: '$e');
      }
    });

    test('both runs the cascade when the denoiser loaded', () {
      final p = plan(NoiseSuppressionEngine.both);
      expect(p.useRnnoise, isTrue);
      expect(p.useSpectral, isTrue);
    });

    test('a stage that does not run is left silent', () {
      final p = plan(NoiseSuppressionEngine.rnnoise);
      expect(p.useSpectral, isFalse);
      expect(p.spectralStrength, 0.0);
    });
  });

  group('does not over-suppress', () {
    test('a running cascade is gentler per stage than either alone', () {
      // Two cleaners in series at the same full strength multiply their
      // residuals, and the second subtracts against a signal whose noise is no
      // longer the stationary kind its floor tracker assumes.
      final cascade = plan(NoiseSuppressionEngine.both, strength: 0.8);
      final soloSpectral = plan(
        NoiseSuppressionEngine.spectral,
        strength: 0.8,
      );
      expect(cascade.spectralStrength, lessThan(soloSpectral.spectralStrength));
      expect(cascade.spectralStrength, 0.8 * SuppressionPlan.mopUpShare);
    });

    test('the primary cleaner keeps the full slider in a cascade', () {
      // RNNoise is the stage trained for this signal; it is the mop-up that is
      // secondary, not the denoiser.
      final p = plan(NoiseSuppressionEngine.both, strength: 0.8);
      expect(p.rnnoiseStrength, 0.8);
    });

    test('collapsing to one cleaner does not also halve it', () {
      // `both` with the native library missing runs spectral *alone*. Handing
      // it the mop-up share there would be a second silent downgrade on the
      // devices that already lost the better engine.
      final p = plan(
        NoiseSuppressionEngine.both,
        strength: 0.8,
        rnnoiseAvailable: false,
      );
      expect(p.useRnnoise, isFalse);
      expect(p.spectralStrength, 0.8);
    });

    test('nothing we ship for the user exceeds the ceiling', () {
      // The finding this whole pass came from: the stock default used to be
      // 1.0, i.e. more aggressive than the profile tuned for a motorcycle.
      expect(
        AppSettings.defaults().noiseSuppression,
        lessThanOrEqualTo(SuppressionPlan.ceiling),
      );
      expect(
        RidingPreset.noiseSuppression,
        lessThanOrEqualTo(SuppressionPlan.ceiling),
      );
      expect(SuppressionPlan.ceiling, lessThan(1.0));
    });

    test('the default is never more aggressive than the riding preset', () {
      // The preset is tuned for the noisiest situation the app has. A desk
      // needs less cleaning than a helmet at road speed, never more.
      expect(
        AppSettings.defaults().noiseSuppression,
        lessThanOrEqualTo(RidingPreset.noiseSuppression),
      );
    });

    test('the slider still reaches full strength when asked', () {
      // The ceiling bounds what we choose for people, not what they may choose
      // for themselves.
      expect(plan(NoiseSuppressionEngine.rnnoise).rnnoiseStrength, 1.0);
      expect(plan(NoiseSuppressionEngine.spectral).spectralStrength, 1.0);
    });
  });

  group('strength', () {
    test('zero stays zero on every engine', () {
      for (final e in NoiseSuppressionEngine.values) {
        final p = plan(e, strength: 0.0);
        expect(p.rnnoiseStrength, 0.0, reason: '$e');
        expect(p.spectralStrength, 0.0, reason: '$e');
      }
    });

    test('out-of-range input is clamped, not propagated', () {
      expect(
        plan(NoiseSuppressionEngine.spectral, strength: 4.2).spectralStrength,
        1.0,
      );
      expect(
        plan(NoiseSuppressionEngine.spectral, strength: -1.0).spectralStrength,
        0.0,
      );
    });
  });
}
