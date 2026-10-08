import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rnnoise/rnnoise.dart';
import 'package:rnnoise/src/rnnoise_bindings.dart';
import 'package:tark/feature/audio/domain/rnnoise_suppressor.dart';

void main() {
  final nativePath = Platform.environment['RNNOISE_LIBRARY_PATH'];
  final legacyPath = Platform.environment['RNNOISE_LEGACY_LIBRARY_PATH'];
  final skipNative = nativePath == null || nativePath.isEmpty
      ? 'Build packages/rnnoise/test and set RNNOISE_LIBRARY_PATH'
      : false;

  test('invalid rates are rejected before native creation', () {
    expect(() => RnnoiseSuppressor(txRateHz: 0), throwsArgumentError);
    expect(() => RnnoiseSuppressor(txRateHz: -1), throwsArgumentError);
    expect(RnnoiseStream.tryCreate(sampleRateHz: 0), isNull);
  });

  test('disposed suppressor cannot process or resurrect on reset', () {
    final suppressor = RnnoiseSuppressor();
    suppressor.dispose();
    suppressor.dispose();
    expect(suppressor.isAvailable, isFalse);
    expect(() => suppressor.process(const []), throwsStateError);
    expect(() => suppressor.reset(), throwsStateError);
  });

  group('real RNNoise native/fallback parity', () {
    for (final rate in [16000, 24000]) {
      for (final strength in [0.0, 0.25, 1.0]) {
        test('$rate Hz strength $strength random chunks, bypass and reset', () {
          final native = RnnoiseSuppressor(txRateHz: rate)..strength = strength;
          final fallback = RnnoiseSuppressor(
            txRateHz: rate,
            preferNative: false,
          )..strength = strength;
          addTearDown(native.dispose);
          addTearDown(fallback.dispose);
          expect(native.usesNativeOrchestration, isTrue);
          expect(fallback.isAvailable, isTrue);
          expect(fallback.usesNativeOrchestration, isFalse);

          final random = Random(324 + rate);
          final source = Float64List.fromList(
            List.generate(rate * 2, (i) {
              if (i < 300) return 0.0;
              if (i == 300) return 0.9;
              return 0.2 * sin(2 * pi * 190 * i / rate) +
                  (random.nextDouble() - 0.5) * 0.12;
            }),
          );
          var offset = 0;
          var blocks = 0;
          while (offset < source.length) {
            // Include single-sample and awkward sub-frame callbacks.
            final count = min(
              blocks % 7 == 0 ? 1 : 1 + random.nextInt(513),
              source.length - offset,
            );
            final input = Float64List.sublistView(
              source,
              offset,
              offset + count,
            );
            final mix = blocks % 29 == 17 ? 0.0 : strength;
            native.strength = mix;
            fallback.strength = mix;
            final actual = native.process(input);
            final expected = fallback.process(input);
            expect(actual.length, count);
            for (var i = 0; i < count; ++i) {
              expect(actual[i].isFinite, isTrue);
              expect(
                actual[i],
                closeTo(expected[i], 2e-9),
                reason: 'rate=$rate block=$blocks sample=$i strength=$mix',
              );
            }
            if (blocks % 13 == 5) {
              expect(native.process(const []), isEmpty);
              expect(fallback.process(const []), isEmpty);
            }
            if (blocks == 47) {
              native.reset();
              fallback.reset();
            }
            offset += count;
            blocks++;
          }
        });
      }

      test('$rate Hz reset matches fresh model including pending frames', () {
        final reset = RnnoiseSuppressor(txRateHz: rate)..strength = 1.0;
        final fresh = RnnoiseSuppressor(txRateHz: rate)..strength = 1.0;
        addTearDown(reset.dispose);
        addTearDown(fresh.dispose);
        expect(reset.usesNativeOrchestration, isTrue);
        reset.process(List.filled(rate ~/ 5 + 7, 0.1));
        reset.reset();
        final input = List.generate(rate ~/ 8, (i) => sin(i * 0.12) * 0.2);
        expect(reset.process(input), fresh.process(input));
      });
    }

    test('native stream validates strength and use after disposal', () {
      final stream = RnnoiseStream.tryCreate(sampleRateHz: 16000);
      expect(stream, isNotNull);
      expect(
        () => stream!.process(const [0.1], strength: double.nan),
        throwsArgumentError,
      );
      stream!.dispose();
      stream.dispose();
      expect(() => stream.process(const [], strength: 0), throwsStateError);
      expect(stream.reset, throwsStateError);
    });

    test('frame API rejects the wrong length and calls after disposal', () {
      final frame = RnnoiseDenoiser.tryCreate();
      expect(frame, isNotNull);
      expect(() => frame!.process(Float32List(1)), throwsArgumentError);
      frame!.dispose();
      frame.dispose();
      expect(() => frame.process(Float32List(480)), throwsStateError);
    });
  }, skip: skipNative);

  test(
    'older native frame ABI remains available without stream symbols',
    () {
      final bindings = RnnoiseBindings(
        library: DynamicLibrary.open(legacyPath!),
      );
      expect(bindings.getFrameSize(), 480);
      expect(bindings.tryStreamBindings(), isNull);
      final state = bindings.create(nullptr);
      expect(state, isNot(nullptr));
      bindings.destroy(state);
    },
    skip: legacyPath == null || legacyPath.isEmpty
        ? 'Set RNNOISE_LEGACY_LIBRARY_PATH to the old-ABI test library'
        : false,
  );
}
