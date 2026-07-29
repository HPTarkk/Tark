// ignore_for_file: avoid_print, avoid_relative_lib_imports
//
// Headless benchmark for the TX audio chain.
//
// Simulates the real mic path: audio_io delivers ~480 frames at 48 kHz every
// 10 ms, which then runs anti-alias low-pass -> 16 kHz resample -> spectral
// noise suppression before frames are emitted. Everything here happens on the
// UI isolate in the app, so per-callback cost is a direct tax on the frame
// budget (16.6 ms at 60 fps).
//
// Run AOT-compiled — JIT numbers are not representative of a release build:
//   dart compile exe scripts/bench_tx.dart -o build/bench_tx.exe && build/bench_tx.exe
import 'dart:math';
import 'dart:typed_data';

import '../lib/feature/audio/domain/resampler.dart';
import '../lib/feature/audio/domain/spectral_noise_suppressor.dart';

const int kInRate = 48000;
const int kOutRate = 16000;
const int kFramesPerPoll = 480; // one 10 ms audio_io poll
const int kPolls = 6000; // 60 s of audio

/// Speech-like signal plus broadband noise, so the suppressor does real work
/// (a silent input lets the noise tracker settle and short-circuits nothing,
/// but a pure tone under-exercises the per-bin gain path).
Float64List _makeSource(int n) {
  final rng = Random(1234);
  final s = Float64List(n);
  for (var i = 0; i < n; i++) {
    final t = i / kInRate;
    s[i] =
        0.30 * sin(2 * pi * 220 * t) * (0.5 + 0.5 * sin(2 * pi * 3 * t)) +
        0.15 * sin(2 * pi * 1100 * t) +
        0.05 * (rng.nextDouble() * 2 - 1);
  }
  return s;
}

/// Today's FFI boundary: `List<double>.generate` boxes every sample.
List<double> boxedChunk(Float64List src, int offset, int count) =>
    List<double>.generate(count, (i) => src[offset + i]);

/// Unboxed equivalent.
Float64List typedChunk(Float64List src, int offset, int count) =>
    Float64List.sublistView(src, offset, offset + count);

class Stats {
  Stats(this.mean, this.p50, this.p99, this.max, this.overFrameBudget);
  final double mean, p50, p99, max;
  final int overFrameBudget;
}

Stats _stats(Float64List samples) {
  final sorted = Float64List.fromList(samples)..sort();
  var sum = 0.0;
  var over = 0;
  for (final v in samples) {
    sum += v;
    if (v > 1000.0) over++; // >1 ms in a single callback = visible risk
  }
  return Stats(
    sum / samples.length,
    sorted[(sorted.length * 0.50).floor()],
    sorted[(sorted.length * 0.99).floor()],
    sorted[sorted.length - 1],
    over,
  );
}

Stats _runChain({required bool boxed, required Float64List src}) {
  final lpA = OnePoleLowPass(sampleRate: kInRate.toDouble(), cutoffHz: 7000);
  final lpB = OnePoleLowPass(sampleRate: kInRate.toDouble(), cutoffHz: 7000);
  final resampler = LinearResampler(
    inRate: kInRate.toDouble(),
    outRate: kOutRate.toDouble(),
  );
  final ns = SpectralNoiseSuppressor()..strength = 0.7;

  var sink = 0.0;
  final timings = Float64List(kPolls);
  final sw = Stopwatch();
  for (var p = 0; p < kPolls; p++) {
    final offset = (p * kFramesPerPoll) % (src.length - kFramesPerPoll);

    sw
      ..reset()
      ..start();
    final List<double> chunk = boxed
        ? boxedChunk(src, offset, kFramesPerPoll)
        : typedChunk(src, offset, kFramesPerPoll);

    var x = lpA.process(chunk);
    x = lpB.process(x);
    x = resampler.process(x);
    if (x.isNotEmpty) {
      final y = ns.process(x);
      sink += y[y.length - 1]; // defeat dead-code elimination
    }
    sw.stop();
    timings[p] = sw.elapsedTicks * 1e6 / sw.frequency;
  }
  if (sink.isNaN) print('unreachable');
  return _stats(timings);
}

void main() {
  final src = _makeSource(kInRate * 4);

  // Warm up so we measure steady state, not first-call codegen.
  _runChain(boxed: true, src: src);
  _runChain(boxed: false, src: src);

  final boxed = _runChain(boxed: true, src: src);
  final typed = _runChain(boxed: false, src: src);

  String row(String label, Stats s) =>
      '  ${label.padRight(24)} mean ${s.mean.toStringAsFixed(1).padLeft(6)}  '
      'p50 ${s.p50.toStringAsFixed(1).padLeft(6)}  '
      'p99 ${s.p99.toStringAsFixed(1).padLeft(6)}  '
      'max ${s.max.toStringAsFixed(1).padLeft(8)}  '
      '>1ms ${s.overFrameBudget}';

  print('TX chain, microseconds per 10 ms mic callback '
      '(AOT, $kPolls polls each)');
  print(row('boxed List<double>', boxed));
  print(row('Float64List', typed));
  print('');
  print('  mean speedup from unboxing: '
      '${(boxed.mean / typed.mean).toStringAsFixed(2)}x   '
      'p99 speedup: ${(boxed.p99 / typed.p99).toStringAsFixed(2)}x   '
      'max speedup: ${(boxed.max / typed.max).toStringAsFixed(2)}x');
}
