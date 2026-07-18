import 'dart:math';
import 'dart:typed_data';

import 'package:rnnoise/rnnoise.dart' as rnn;

import 'resampler.dart';

/// Alternative to [SpectralNoiseSuppressor] on the 16 kHz TX path: a
/// recurrent-network denoiser (RNNoise), which — unlike spectral subtraction
/// — was trained on non-stationary noise (wind, traffic) and doesn't need a
/// noise floor to "lock onto" first.
///
/// RNNoise only runs at 48 kHz in fixed 480-sample (10 ms) frames, so this
/// wraps it with an up/48k-process/down round trip: the 16 kHz tap stays the
/// wire format (bandwidth stays exactly as before), only the noise-reduction
/// stage itself runs at RNNoise's native rate — the same shape real
/// call-processing pipelines use, where the DSP/NN stage's internal rate is
/// decoupled from the codec's. Since 48000/16000 is an exact 3:1 ratio,
/// there's no long-run sample-rate drift from the round trip.
///
/// [strength] 0 disables (pure passthrough); 1 uses RNNoise's output
/// unmixed. Intermediate values cross-fade dry/wet — RNNoise itself has no
/// native "strength" knob. Output is delayed relative to input by the
/// pipeline's startup latency (roughly one 480-sample RNNoise frame's worth
/// of 16 kHz-equivalent samples); output length always equals input length.
class RnnoiseSuppressor {
  static const int _rnnRate = 48000;
  static const int _txRate = 16000;

  /// Matches the reference `rnnoise_demo`: it feeds RNNoise int16 samples
  /// cast straight to float, so normalised [-1, 1] doubles need this scale
  /// applied going in (and undone coming out) to land in the range RNNoise
  /// was trained on.
  static const double _pcmScale = 32768.0;

  double strength = 0.0;

  rnn.RnnoiseDenoiser? _denoiser = rnn.RnnoiseDenoiser.tryCreate();

  /// False when the native library couldn't be loaded (e.g. this platform's
  /// build hasn't compiled it in yet) — callers should keep the spectral
  /// suppressor as the active engine in that case.
  bool get isAvailable => _denoiser != null;

  final LinearResampler _up = LinearResampler(
    inRate: _txRate.toDouble(),
    outRate: _rnnRate.toDouble(),
  );
  final LinearResampler _down = LinearResampler(
    inRate: _rnnRate.toDouble(),
    outRate: _txRate.toDouble(),
  );

  final List<double> _rnnIn = []; // 48 kHz, awaiting a full 480-sample frame
  final List<double> _out16k = []; // 16 kHz denoised, awaiting emission
  final List<double> _dry16k = []; // 16 kHz dry, paired 1:1 with _out16k

  /// Process a block of any length; returns the same number of samples.
  List<double> process(List<double> samples) {
    final denoiser = _denoiser;
    if (strength <= 0.0 || denoiser == null) {
      if (_rnnIn.isNotEmpty || _out16k.isNotEmpty || _dry16k.isNotEmpty) {
        _clearBuffers();
      }
      return samples;
    }
    if (samples.isEmpty) return samples;

    _dry16k.addAll(samples);

    _rnnIn.addAll(_up.process(samples));
    final frameSize = denoiser.frameSize;
    while (_rnnIn.length >= frameSize) {
      final frame = Float32List(frameSize);
      for (var i = 0; i < frameSize; i++) {
        frame[i] = _rnnIn[i] * _pcmScale;
      }
      _rnnIn.removeRange(0, frameSize);

      final (wetFrame, _) = denoiser.process(frame);
      final wet16k = _down.process(
        List<double>.generate(
          frameSize,
          (i) => wetFrame[i] / _pcmScale,
          growable: false,
        ),
      );
      _out16k.addAll(wet16k);
    }

    final take = min(_out16k.length, samples.length);
    final offset = samples.length - take; // > 0 only during startup latency
    final total = offset + take;
    final out = List<double>.filled(samples.length, 0.0);
    for (var i = 0; i < offset; i++) {
      out[i] = _dry16k[i]; // wet path hasn't produced output yet
    }
    for (var i = 0; i < take; i++) {
      final dry = _dry16k[offset + i];
      out[offset + i] = dry + (_out16k[i] - dry) * strength;
    }
    _dry16k.removeRange(0, total);
    _out16k.removeRange(0, take);
    return out;
  }

  void _clearBuffers() {
    _up.reset();
    _down.reset();
    _rnnIn.clear();
    _out16k.clear();
    _dry16k.clear();
  }

  /// Clears all streaming state, including the RNN's internal history —
  /// unlike the spectral suppressor's noise floor, RNNoise has no public API
  /// to reset hidden state short of recreating it. Call when the audio
  /// session restarts.
  void reset() {
    _clearBuffers();
    _denoiser?.dispose();
    _denoiser = rnn.RnnoiseDenoiser.tryCreate();
  }

  /// Frees the native RNN state. Call when the owning engine is disposed.
  void dispose() {
    _denoiser?.dispose();
    _denoiser = null;
  }
}
