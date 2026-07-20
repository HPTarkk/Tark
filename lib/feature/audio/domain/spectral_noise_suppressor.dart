import 'dart:math';
import 'dart:typed_data';

import 'float64_fifo.dart';

/// Streaming spectral noise suppressor for the 16 kHz TX path.
///
/// Classic short-time spectral subtraction, the same family of algorithm
/// used in two-way radios and VoIP noise reduction:
///
///   1. STFT: sqrt-Hann windows of 256 samples (16 ms) with 50% overlap.
///   2. Per-frequency-bin noise floor tracking: the estimate falls quickly
///      when a bin's power drops (silence between words) and creeps up
///      slowly otherwise, so it locks onto *stationary* noise — wind hiss,
///      engine drone — without absorbing speech, which is heavily modulated.
///   3. Per-bin gain: over-subtraction of the tracked floor with a strength-
///      dependent attenuation floor, smoothed over time and across
///      neighbouring bins to avoid "musical noise" artifacts.
///   4. Inverse FFT + overlap-add with a matching synthesis window.
///
/// This runs BEFORE the VOX RMS decision on purpose: with the stationary
/// noise removed, road/wind noise no longer drives the RMS level, so the VOX
/// threshold can sit low enough to catch quiet speech without the channel
/// keying up on engine noise — the failure mode this class exists to fix.
///
/// [strength] 0 disables (pure passthrough); 1 is maximum suppression
/// (up to ~-30 dB on noise-only bins). The output is delayed by one hop
/// (8 ms) relative to the input; output length always equals input length.
class SpectralNoiseSuppressor {
  static const int _win = 256;
  static const int _hop = 128;
  static const int _bins = _win ~/ 2; // bins 0.._bins (Nyquist inclusive)

  /// Suppression strength, 0..1. Mutable so the UI slider takes effect
  /// immediately; 0 bypasses processing entirely.
  double strength = 0.0;

  final _Fft _fft = _Fft(_win);
  final Float64List _window = _buildSqrtHann();

  // Unboxed ring buffers — see Float64Fifo: growable List<double> here boxed
  // every sample and shifted the remainder on each hop, i.e. steady GC churn
  // at audio rate.
  final Float64Fifo _inFifo = Float64Fifo();
  final Float64Fifo _outFifo = Float64Fifo();
  final Float64List _re = Float64List(_win);
  final Float64List _im = Float64List(_win);
  final Float64List _ola = Float64List(_win);
  final Float64List _pSm = Float64List(_bins + 1);
  final Float64List _noise = Float64List(_bins + 1);
  final Float64List _gain = Float64List(_bins + 1);
  final Float64List _gainSm = Float64List(_bins + 1);
  int _hopsProcessed = 0;

  static Float64List _buildSqrtHann() {
    // Periodic Hann: w²(n) sums to exactly 1 at 50% overlap, so
    // analysis+synthesis windowing reconstructs perfectly at unity gain.
    final w = Float64List(_win);
    for (var i = 0; i < _win; i++) {
      w[i] = sqrt(0.5 * (1.0 - cos(2.0 * pi * i / _win)));
    }
    return w;
  }

  /// Process a block of any length; returns the same number of samples.
  List<double> process(List<double> samples) {
    if (strength <= 0.0) {
      // Bypass. Drop any half-processed state so re-enabling starts clean
      // (tiny glitch when the slider crosses zero, inaudible in practice).
      if (_inFifo.isNotEmpty || _outFifo.isNotEmpty) reset();
      return samples;
    }
    if (samples.isEmpty) return samples;

    _inFifo.addAll(samples);
    while (_inFifo.length >= _win) {
      _processHop();
    }

    // Emit exactly samples.length. Early calls run short by the algorithmic
    // latency (one hop) — pad those with leading silence once at stream
    // start; afterwards production and consumption rates are identical.
    final out = Float64List(samples.length);
    final take = _outFifo.length < samples.length
        ? _outFifo.length
        : samples.length;
    final offset = samples.length - take;
    for (var i = 0; i < take; i++) {
      out[offset + i] = _outFifo[i];
    }
    _outFifo.discardFirst(take);
    return out;
  }

  void _processHop() {
    for (var i = 0; i < _win; i++) {
      _re[i] = _inFifo[i] * _window[i];
      _im[i] = 0.0;
    }
    _inFifo.discardFirst(_hop);

    _fft.transform(_re, _im, inverse: false);

    // Strength mapping: more aggressive floor subtraction and a deeper
    // attenuation floor as the slider goes up. The base over-subtraction is
    // 2 (not 1) because the minimum-tracking floor estimate below sits under
    // the true noise mean by design; without the headroom, gains computed
    // against it leak a large fraction of the noise through.
    final beta = 2.0 + 2.0 * strength; // over-subtraction factor 2..4
    final gMin = pow(10.0, -30.0 * strength / 20.0).toDouble(); // 0..-30 dB

    for (var k = 0; k <= _bins; k++) {
      final p = _re[k] * _re[k] + _im[k] * _im[k];

      // Smooth the periodogram: single-hop bin power of broadband noise is
      // wildly spiky (exponentially distributed), and gains computed from
      // raw p both leak the spikes and drag the floor tracker down to the
      // minima instead of the noise level.
      final ps = _hopsProcessed == 0 ? p : 0.7 * _pSm[k] + 0.3 * p;
      _pSm[k] = ps;

      // Noise floor tracking (asymmetric):
      var n = _noise[k];
      if (_hopsProcessed < 30) {
        // Prime quickly from the first ~240 ms; if the user talks straight
        // away the downward tracking below corrects within a few
        // speech pauses.
        n = _hopsProcessed == 0 ? ps : 0.9 * n + 0.1 * ps;
      } else if (ps < n) {
        n += 0.15 * (ps - n); // fall toward the true floor in speech gaps
      } else {
        n = min(n * 1.012, ps); // creep up ~6 dB/s toward sustained noise
      }
      _noise[k] = n;

      // Power spectral subtraction gain.
      var g = 1.0 - beta * n / (ps + 1e-12);
      if (g < gMin) g = gMin;
      if (g > 1.0) g = 1.0;

      // Temporal smoothing: open fast on speech onsets, close a bit slower
      // so word tails aren't clipped.
      final prev = _gain[k];
      g = prev + (g > prev ? 0.5 : 0.3) * (g - prev);
      _gain[k] = g;
    }

    // Smooth across neighbouring bins — isolated single-bin gains are what
    // produce warbling "musical noise".
    _gainSm[0] = _gain[0];
    _gainSm[_bins] = _gain[_bins];
    for (var k = 1; k < _bins; k++) {
      _gainSm[k] = 0.25 * _gain[k - 1] + 0.5 * _gain[k] + 0.25 * _gain[k + 1];
    }

    // Apply gains (respecting conjugate symmetry of the real-signal FFT).
    for (var k = 0; k <= _bins; k++) {
      final g = _gainSm[k];
      _re[k] *= g;
      _im[k] *= g;
      if (k > 0 && k < _bins) {
        _re[_win - k] *= g;
        _im[_win - k] *= g;
      }
    }

    _fft.transform(_re, _im, inverse: true);

    // Overlap-add with the synthesis window, emit one hop.
    for (var i = 0; i < _win; i++) {
      _ola[i] += _re[i] * _window[i];
    }
    _outFifo.addAll(Float64List.sublistView(_ola, 0, _hop));
    for (var i = 0; i < _win - _hop; i++) {
      _ola[i] = _ola[i + _hop];
    }
    for (var i = _win - _hop; i < _win; i++) {
      _ola[i] = 0.0;
    }

    _hopsProcessed++;
  }

  /// Clear all streaming state (keeps [strength]). Call when the audio
  /// session restarts so a stale noise profile from the previous session
  /// doesn't suppress the new one.
  void reset() {
    _inFifo.clear();
    _outFifo.clear();
    _ola.fillRange(0, _win, 0.0);
    _pSm.fillRange(0, _bins + 1, 0.0);
    _noise.fillRange(0, _bins + 1, 0.0);
    _gain.fillRange(0, _bins + 1, 0.0);
    _gainSm.fillRange(0, _bins + 1, 0.0);
    _hopsProcessed = 0;
  }
}

// ── FFT ───────────────────────────────────────────────────────────────────────

/// Iterative radix-2 Cooley-Tukey FFT on split re/im arrays, with
/// precomputed twiddle factors and bit-reversal table.
class _Fft {
  _Fft(this.size)
    : assert((size & (size - 1)) == 0, 'FFT size must be a power of two'),
      _bitRev = Uint32List(size),
      _cos = Float64List(size ~/ 2),
      _sin = Float64List(size ~/ 2) {
    for (var i = 1, j = 0; i < size; i++) {
      var bit = size >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      _bitRev[i] = j;
    }
    for (var k = 0; k < size ~/ 2; k++) {
      final angle = -2.0 * pi * k / size;
      _cos[k] = cos(angle);
      _sin[k] = sin(angle);
    }
  }

  final int size;
  final Uint32List _bitRev;
  final Float64List _cos;
  final Float64List _sin;

  void transform(Float64List re, Float64List im, {required bool inverse}) {
    for (var i = 0; i < size; i++) {
      final j = _bitRev[i];
      if (j > i) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }

    for (var len = 2; len <= size; len <<= 1) {
      final half = len >> 1;
      final step = size ~/ len;
      for (var i = 0; i < size; i += len) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = inverse ? -_sin[k * step] : _sin[k * step];
          final hi = i + k + half;
          final lo = i + k;
          final xr = re[hi];
          final xi = im[hi];
          final tr = xr * wr - xi * wi;
          final ti = xr * wi + xi * wr;
          re[hi] = re[lo] - tr;
          im[hi] = im[lo] - ti;
          re[lo] += tr;
          im[lo] += ti;
        }
      }
    }

    if (inverse) {
      final scale = 1.0 / size;
      for (var i = 0; i < size; i++) {
        re[i] *= scale;
        im[i] *= scale;
      }
    }
  }
}
