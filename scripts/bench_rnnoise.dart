// ignore_for_file: avoid_print, avoid_relative_lib_imports
//
// Build the exact native sources with packages/rnnoise/test/CMakeLists.txt in
// Release mode, set RNNOISE_LIBRARY_PATH to its host shared library, then run:
// dart compile exe scripts/bench_rnnoise.dart -o build/bench_rnnoise.exe
// build/bench_rnnoise.exe
import 'dart:math';
import 'dart:typed_data';

import '../lib/feature/audio/domain/rnnoise_suppressor.dart';

const polls = 3000;

Float64List source(int rate) {
  final random = Random(324);
  return Float64List.fromList(
    List.generate(rate * 2, (i) {
      final t = i / rate;
      return 0.2 * sin(2 * pi * 190 * t) * (0.7 + 0.3 * sin(2 * pi * 3 * t)) +
          0.07 * sin(2 * pi * 1100 * t) +
          (random.nextDouble() - 0.5) * 0.12;
    }),
  );
}

void benchmark(int rate, bool native, double strength) {
  final suppressor = RnnoiseSuppressor(txRateHz: rate, preferNative: native)
    ..strength = strength;
  if (!suppressor.isAvailable || suppressor.usesNativeOrchestration != native) {
    suppressor.dispose();
    throw StateError('Build and load RNNOISE_LIBRARY_PATH before benchmarking');
  }
  final samples = source(rate);
  final count = rate ~/ 100;
  final chunks = [
    for (var i = 0; i < samples.length; i += count)
      Float64List.sublistView(samples, i, i + count),
  ];
  for (var i = 0; i < 100; ++i) {
    suppressor.process(chunks[i % chunks.length]);
  }
  final timings = Float64List(polls);
  final watch = Stopwatch();
  var checksum = 0.0;
  for (var i = 0; i < polls; ++i) {
    final input = chunks[i % chunks.length];
    watch
      ..reset()
      ..start();
    final output = suppressor.process(input);
    watch.stop();
    timings[i] = watch.elapsedTicks * 1e6 / watch.frequency;
    checksum += output.last;
  }
  suppressor.dispose();
  if (!checksum.isFinite) throw StateError('Nonfinite benchmark output');
  final sorted = Float64List.fromList(timings)..sort();
  final mean = timings.reduce((a, b) => a + b) / polls;
  print(
    '$rate Hz ${native ? 'native' : 'Dart  '} strength=$strength: '
    'mean ${mean.toStringAsFixed(2)} us, '
    'p50 ${sorted[polls ~/ 2].toStringAsFixed(2)} us, '
    'p99 ${sorted[(polls * 0.99).floor()].toStringAsFixed(2)} us, '
    'max ${sorted.last.toStringAsFixed(2)} us',
  );
}

void main() {
  print('RNNoise: actual inference, AOT, $polls callbacks of 10 ms per row');
  for (final rate in [16000, 24000]) {
    for (final strength in [1.0, 0.0]) {
      benchmark(rate, false, strength);
      benchmark(rate, true, strength);
    }
  }
}
