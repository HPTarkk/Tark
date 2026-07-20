import 'dart:typed_data';

import 'dart:math';

/// Continuous linear-interpolation sample-rate converter.
///
/// Keeps a fractional position and a small history tail across calls so
/// resampling a stream of arbitrarily-sized chunks produces the same result
/// as resampling it as one contiguous buffer — no clicks or pitch jumps at
/// chunk boundaries.
///
/// Works entirely in typed arrays: this runs on every mic callback, and
/// growable `List<double>` output boxed each emitted sample, which at audio
/// rate was a steady source of GC pressure (visible as UI pauses).
class LinearResampler {
  LinearResampler({required this.inRate, required this.outRate});

  final double inRate;
  final double outRate;

  double _phase = 0.0;
  Float64List _history = Float64List(0);

  List<double> process(List<double> input) {
    if (input.isEmpty) return const [];
    final samples = Float64List(_history.length + input.length);
    samples.setRange(0, _history.length, _history);
    for (var i = 0; i < input.length; i++) {
      samples[_history.length + i] = input[i];
    }
    final ratio = inRate / outRate;

    // Upper bound on output count; the loop below fills `n <= maxOut`.
    final maxOut = ((samples.length - _phase) / ratio).ceil() + 1;
    final out = Float64List(maxOut);
    var n = 0;

    double pos = _phase;
    while (true) {
      final i0 = pos.floor();
      final i1 = i0 + 1;
      if (i1 >= samples.length) break;
      final frac = pos - i0;
      out[n++] = samples[i0] + (samples[i1] - samples[i0]) * frac;
      pos += ratio;
    }

    final consumedWhole = pos.floor().clamp(0, samples.length - 1);
    _history = samples.sublist(consumedWhole);
    _phase = pos - consumedWhole;
    return Float64List.sublistView(out, 0, n);
  }

  void reset() {
    _phase = 0.0;
    _history = Float64List(0);
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
    final out = Float64List(input.length);
    for (int i = 0; i < input.length; i++) {
      _y += _alpha * (input[i] - _y);
      out[i] = _y;
    }
    return out;
  }
}
