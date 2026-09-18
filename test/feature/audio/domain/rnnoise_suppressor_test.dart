import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/audio/audio_format_profile.dart';
import 'package:tark/feature/audio/domain/rnnoise_suppressor.dart';

void main() {
  group('construction at both #28 target rates', () {
    // Both AudioFormatProfile.legacy16k (48000/16000 = 3:1) and .hd24k
    // (48000/24000 = 2:1) are exact ratios against RNNoise's fixed native
    // rate — see the class doc. This doesn't exercise the native denoiser
    // (unavailable in this test environment — see the strength>0 group
    // below), just that construction and the passthrough path work
    // identically at both rates.
    for (final rate in [
      AudioFormatProfile.legacy16k.sampleRateHz,
      AudioFormatProfile.hd24k.sampleRateHz,
    ]) {
      group('at ${rate}Hz', () {
        test('strength 0 is a bit-exact passthrough', () {
          final rn = RnnoiseSuppressor(txRateHz: rate)..strength = 0.0;
          final block = List<double>.generate(320, (i) => (i % 100) / 100);
          final out = rn.process(block);
          expect(out, block);
        });

        test('output length always equals input length at strength 0', () {
          final rn = RnnoiseSuppressor(txRateHz: rate)..strength = 0.0;
          for (final n in [320, 100, 7, 512, 1, 0]) {
            expect(rn.process(List<double>.filled(n, 0.01)).length, n);
          }
        });

        test('empty input is a no-op', () {
          final rn = RnnoiseSuppressor(txRateHz: rate)..strength = 0.5;
          expect(rn.process(const []), isEmpty);
        });

        test('reset and dispose do not throw', () {
          final rn = RnnoiseSuppressor(txRateHz: rate);
          rn.reset();
          rn.dispose();
        });
      });
    }

    test('the default constructor matches legacy16k explicitly', () {
      final withDefault = RnnoiseSuppressor()..strength = 0.0;
      final withExplicit = RnnoiseSuppressor(
        txRateHz: AudioFormatProfile.legacy16k.sampleRateHz,
      )..strength = 0.0;
      final block = List<double>.generate(320, (i) => (i % 100) / 100);
      expect(withDefault.process(block), withExplicit.process(block));
    });
  });

  // The native denoiser doesn't load in this test environment (no platform
  // FFI binary), so strength>0 always falls back to passthrough here
  // regardless of rate — this pins that fallback rather than pretending the
  // resample+denoise path is exercised. Real 3:1/2:1 ratio correctness under
  // the native library needs a device run, not this suite.
  group('strength > 0 without a loaded native denoiser', () {
    for (final rate in [
      AudioFormatProfile.legacy16k.sampleRateHz,
      AudioFormatProfile.hd24k.sampleRateHz,
    ]) {
      test('${rate}Hz falls back to passthrough when isAvailable is false', () {
        final rn = RnnoiseSuppressor(txRateHz: rate)..strength = 1.0;
        if (rn.isAvailable) {
          // The native library did load on whatever machine runs this —
          // nothing to assert here beyond "it didn't throw"; the fallback
          // path this group is pinning doesn't apply.
          return;
        }
        final block = List<double>.generate(320, (i) => (i % 100) / 100);
        expect(rn.process(block), block);
      });
    }
  });
}
