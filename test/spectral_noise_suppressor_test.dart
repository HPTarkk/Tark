import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/spectral_noise_suppressor.dart';

double _rms(List<double> x) {
  if (x.isEmpty) return 0;
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return sqrt(s / x.length);
}

void main() {
  test('strength 0 is a bit-exact passthrough', () {
    final ns = SpectralNoiseSuppressor()..strength = 0.0;
    final block = List<double>.generate(320, (i) => sin(i * 0.1));
    final out = ns.process(block);
    expect(out.length, 320);
    for (var i = 0; i < 320; i++) {
      expect(out[i], closeTo(block[i], 1e-12));
    }
  });

  test('output length always equals input length', () {
    final ns = SpectralNoiseSuppressor()..strength = 0.8;
    for (final n in [320, 100, 7, 512, 1, 320, 320]) {
      expect(ns.process(List<double>.filled(n, 0.01)).length, n);
    }
  });

  test('stationary noise is strongly attenuated, speech bursts survive', () {
    final rand = Random(42);
    const noiseAmp = 0.1;
    List<double> makeNoise(int n) => List<double>.generate(
        n, (_) => (rand.nextDouble() * 2 - 1) * noiseAmp);

    final ns = SpectralNoiseSuppressor()..strength = 1.0;

    // Warmup: 2 s of noise so the floor estimate settles.
    for (var i = 0; i < 100; i++) {
      ns.process(makeNoise(320));
    }

    // Noise-only attenuation.
    var inRms = 0.0, outRms = 0.0;
    for (var i = 0; i < 50; i++) {
      final inp = makeNoise(320);
      final out = ns.process(inp);
      inRms += _rms(inp);
      outRms += _rms(out);
    }
    final noiseReductionDb = 20 * log(outRms / inRms) / ln10;
    expect(noiseReductionDb, lessThan(-15),
        reason: 'noise attenuation was ${noiseReductionDb.toStringAsFixed(1)} dB');

    // Speech-like tone bursts (300 Hz + 1.2 kHz, 200 ms on/off) over the
    // same noise must pass with only mild level change.
    var t = 0;
    double speechSample() {
      final on = (t ~/ 3200) % 2 == 0;
      final v = on
          ? 0.3 * sin(2 * pi * 300 * t / 16000) +
              0.2 * sin(2 * pi * 1200 * t / 16000)
          : 0.0;
      t++;
      return v;
    }

    var inSpeech = 0.0, outSpeech = 0.0;
    for (var i = 0; i < 300; i++) {
      final speech = List<double>.generate(320, (_) => speechSample());
      final inp = makeNoise(320);
      for (var j = 0; j < 320; j++) {
        inp[j] += speech[j];
      }
      final out = ns.process(inp);
      if (_rms(speech) > 0.1) {
        inSpeech += _rms(inp);
        outSpeech += _rms(out);
      }
    }
    final speechChangeDb = 20 * log(outSpeech / inSpeech) / ln10;
    expect(speechChangeDb, greaterThan(-6),
        reason: 'speech level change was ${speechChangeDb.toStringAsFixed(1)} dB');
  });
}
