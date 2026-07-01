import 'dart:math';

/// Continuous linear-interpolation sample-rate converter.
///
/// Keeps a fractional position and a small history tail across calls so
/// resampling a stream of arbitrarily-sized chunks produces the same result
/// as resampling it as one contiguous buffer — no clicks or pitch jumps at
/// chunk boundaries.
class LinearResampler {
  LinearResampler({required this.inRate, required this.outRate});

  final double inRate;
  final double outRate;

  double _phase = 0.0;
  List<double> _history = const [];

  List<double> process(List<double> input) {
    if (input.isEmpty) return const [];
    final samples = [..._history, ...input];
    final ratio = inRate / outRate;
    final out = <double>[];

    double pos = _phase;
    while (true) {
      final i0 = pos.floor();
      final i1 = i0 + 1;
      if (i1 >= samples.length) break;
      final frac = pos - i0;
      out.add(samples[i0] + (samples[i1] - samples[i0]) * frac);
      pos += ratio;
    }

    final consumedWhole = pos.floor().clamp(0, samples.length - 1);
    _history = samples.sublist(consumedWhole);
    _phase = pos - consumedWhole;
    return out;
  }

  void reset() {
    _phase = 0.0;
    _history = const [];
  }
}

/// Simple one-pole low-pass, used as an anti-aliasing filter before
/// downsampling so energy above the new Nyquist frequency doesn't fold back
/// into the voice band as noise.
class OnePoleLowPass {
  OnePoleLowPass({required double sampleRate, required double cutoffHz})
      : _alpha = _computeAlpha(sampleRate, cutoffHz);

  final double _alpha;
  double _y = 0.0;

  static double _computeAlpha(double sampleRate, double cutoffHz) {
    final rc = 1.0 / (2 * pi * cutoffHz);
    final dt = 1.0 / sampleRate;
    return dt / (rc + dt);
  }

  List<double> process(List<double> input) {
    final out = List<double>.filled(input.length, 0.0);
    for (int i = 0; i < input.length; i++) {
      _y += _alpha * (input[i] - _y);
      out[i] = _y;
    }
    return out;
  }
}
