import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_io/realtime_dsp.dart';
import 'package:audio_io/src/ffi/audio_io_bindings.dart';
import 'package:audio_io/src/ffi/audio_io_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/audio/domain/resampler.dart';
import 'package:tark/feature/audio/domain/spectral_noise_suppressor.dart';

Float64List _signal(int count, int rate, {int seed = 731}) {
  final random = Random(seed);
  return Float64List.fromList(
    List<double>.generate(count, (i) {
      if ((i ~/ (rate ~/ 3)) % 7 == 5) return 0.0;
      final noise = (random.nextDouble() * 2 - 1) * 0.08;
      final speech = (i ~/ (rate ~/ 5)) % 2 == 0 && i > rate ~/ 2;
      return noise +
          (speech
              ? 0.3 * sin(2 * pi * 300 * i / rate) +
                    0.2 * sin(2 * pi * 1200 * i / rate)
              : 0.0);
    }),
  );
}

void _sameSamples(
  List<double> actual,
  List<double> expected, {
  double tolerance = 1e-10,
  String? reason,
}) {
  expect(actual.length, expected.length, reason: reason);
  var maxError = 0.0;
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i].isFinite, isTrue, reason: reason);
    maxError = max(maxError, (actual[i] - expected[i]).abs());
  }
  expect(maxError, lessThanOrEqualTo(tolerance), reason: reason);
}

Iterable<Float64List> _chunks(Float64List signal, int seed) sync* {
  final random = Random(seed);
  const edges = [1, 7, 63, 127, 128, 255, 256, 257, 320, 480, 512, 4096];
  var at = 0;
  var block = 0;
  while (at < signal.length) {
    if (block % 11 == 0) yield Float64List(0);
    final requested = block < edges.length
        ? edges[block]
        : 1 + random.nextInt(2300);
    final n = min(requested, signal.length - at);
    yield Float64List.sublistView(signal, at, at + n);
    at += n;
    block++;
  }
}

void main() {
  test(
    'Dart low-pass stays finite for all accepted positive finite scales',
    () {
      for (final rate in [
        double.minPositive,
        1e-300,
        48000.0,
        double.maxFinite,
      ]) {
        for (final cutoff in [
          double.minPositive,
          1.0,
          7200.0,
          double.maxFinite,
        ]) {
          final filter = OnePoleLowPass(sampleRate: rate, cutoffHz: cutoff);
          final actual = filter.process([1.0, -1.0, 0.5, 0.0]);
          expect(
            actual.every((value) => value.isFinite && value.abs() <= 1),
            isTrue,
          );
        }
      }
    },
  );

  test('Dart spectral fallback satisfies the realtime interface', () {
    final RealtimeSpectralSuppressor fallback = SpectralNoiseSuppressor();
    expect(fallback.process([0.25, -0.5]), isA<Float64List>());
    expect(fallback.process([0.25, -0.5]), [0.25, -0.5]);
    fallback.strength = 0.8;
    fallback.process(_signal(4000, 16000));
    fallback.dispose();
    final fresh = SpectralNoiseSuppressor()..strength = 0.8;
    _sameSamples(
      fallback.process(_signal(320, 16000)),
      fresh.process(_signal(320, 16000)),
      tolerance: 0,
    );
  });

  final libraryPath = Platform.environment['AUDIO_IO_TEST_LIBRARY'];
  group(
    'production native DSP parity',
    () {
      late AudioIoBindings bindings;
      setUpAll(() {
        bindings = AudioIoBindings.realtimeDsp(
          DynamicLibrary.open(libraryPath!),
        );
        expect(bindings.hasResampler, isTrue);
        expect(bindings.hasLowPass, isTrue);
        expect(bindings.hasSpectralSuppressor, isTrue);
      });

      for (final rate in [16000, 24000]) {
        test('spectral $rate Hz empty bypass call clears partial state', () {
          final native = FfiRealtimeSpectralSuppressor.create(bindings, rate)
            ..strength = 0.8;
          final reference = SpectralNoiseSuppressor(sampleRateHz: rate)
            ..strength = 0.8;
          addTearDown(native.dispose);
          final input = _signal(3000, rate);
          _sameSamples(native.process(input), reference.process(input));
          native.strength = reference.strength = 0.0;
          _sameSamples(native.process(const []), reference.process(const []));
          native.strength = reference.strength = 0.8;
          _sameSamples(native.process(input), reference.process(input));
        });

        for (final strength in [0.0, 0.01, 0.25, 0.5, 0.8, 1.0]) {
          test('spectral $rate Hz strength $strength randomized chunks', () {
            final native = FfiRealtimeSpectralSuppressor.create(bindings, rate)
              ..strength = strength;
            final reference = SpectralNoiseSuppressor(sampleRateHz: rate)
              ..strength = strength;
            addTearDown(native.dispose);
            var block = 0;
            for (final input in _chunks(_signal(rate * 3, rate), 731)) {
              final actual = native.process(input);
              final expected = reference.process(input);
              expect(actual.length, input.length);
              _sameSamples(
                actual,
                expected,
                reason: '$rate Hz, strength $strength, block ${block++}',
              );
              if (strength == 0) _sameSamples(actual, input, tolerance: 0);
            }
          });
        }

        test('spectral $rate Hz long stream, reset, bypass and silence', () {
          final native = FfiRealtimeSpectralSuppressor.create(bindings, rate);
          final reference = SpectralNoiseSuppressor(sampleRateHz: rate);
          addTearDown(native.dispose);
          final input = _signal(rate * 20, rate, seed: 1934);
          var block = 0;
          for (final chunk in _chunks(input, 1934)) {
            // Slider updates include zero crossings while windows are partial.
            final strength = [0.8, 0.0, 1.0, 0.25][(block ~/ 37) % 4];
            native.strength = reference.strength = strength;
            if (block % 83 == 0) {
              native.reset();
              reference.reset();
            }
            _sameSamples(
              native.process(chunk),
              reference.process(chunk),
              reason: '$rate Hz long stream block ${block++}',
            );
          }
          native.reset();
          reference.reset();
          native.strength = reference.strength = 1.0;
          for (final chunk in _chunks(Float64List(rate * 2), 12)) {
            final actual = native.process(chunk);
            _sameSamples(actual, reference.process(chunk), tolerance: 0);
            expect(actual.every((sample) => sample == 0), isTrue);
          }
          final restart = _signal(rate, rate);
          native.reset();
          final fresh = SpectralNoiseSuppressor(sampleRateHz: rate)
            ..strength = 1.0;
          _sameSamples(native.process(restart), fresh.process(restart));
        });
      }

      for (final rates in [
        (48000.0, 16000.0),
        (48000.0, 24000.0),
        (16000.0, 48000.0),
        (24000.0, 48000.0),
        (44100.0, 16000.0),
        (44100.0, 24000.0),
        (48000.0, 44100.0),
        (24000.0, 44100.0),
        (48000.0, 1000.0),
        (16000.0, 16000.0),
      ]) {
        test('resampler ${rates.$1} to ${rates.$2} state and reset', () {
          final native = FfiRealtimeResampler.create(
            bindings,
            rates.$1,
            rates.$2,
          );
          final reference = LinearResampler(
            inRate: rates.$1,
            outRate: rates.$2,
          );
          addTearDown(native.dispose);
          final input = _signal(48007, rates.$1.toInt());
          for (final chunk in _chunks(input, 73)) {
            _sameSamples(
              native.process(chunk),
              reference.process(chunk),
              tolerance: 2e-12,
            );
          }
          native.reset();
          reference.reset();
          _sameSamples(
            native.process(input),
            reference.process(input),
            tolerance: 2e-12,
          );
        });
      }

      test(
        'resampler retains tiny zero-output blocks at high downsampling',
        () {
          final native = FfiRealtimeResampler.create(bindings, 48000, 1000);
          final reference = LinearResampler(inRate: 48000, outRate: 1000);
          addTearDown(native.dispose);
          for (var i = 0; i < 1000; i++) {
            final input = [i.toDouble() / 1000];
            _sameSamples(
              native.process(input),
              reference.process(input),
              tolerance: 0,
            );
          }
        },
      );

      for (final rate in [16000.0, 24000.0, 44100.0, 48000.0]) {
        test('one-pole low-pass $rate Hz matches Dart across chunks', () {
          final native = FfiRealtimeLowPass.create(bindings, rate, rate * 0.15);
          final reference = OnePoleLowPass(
            sampleRate: rate,
            cutoffHz: rate * 0.15,
          );
          addTearDown(native.dispose);
          final input = _signal(48007, rate.toInt());
          for (final chunk in _chunks(input, 473)) {
            _sameSamples(
              native.process(chunk),
              reference.process(chunk),
              tolerance: 2e-12,
            );
          }
          native.reset();
          reference.reset();
          _sameSamples(
            native.process(input),
            reference.process(input),
            tolerance: 2e-12,
          );
        });
      }

      test('one-pole low-pass native parity at extreme finite scales', () {
        for (final rate in [double.minPositive, 1e-300, double.maxFinite]) {
          for (final cutoff in [double.minPositive, 1.0, double.maxFinite]) {
            final native = FfiRealtimeLowPass.create(bindings, rate, cutoff);
            final reference = OnePoleLowPass(
              sampleRate: rate,
              cutoffHz: cutoff,
            );
            try {
              _sameSamples(
                native.process([1.0, -1.0, 0.5, 0.0]),
                reference.process([1.0, -1.0, 0.5, 0.0]),
                tolerance: 0,
              );
            } finally {
              native.dispose();
            }
          }
        }
      });
    },
    skip: libraryPath == null
        ? 'Set AUDIO_IO_TEST_LIBRARY to test native DSP'
        : false,
  );
}
