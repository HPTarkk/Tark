import 'dart:math';
import 'dart:typed_data';

import 'package:rnnoise/rnnoise.dart' as rnn;

import '../../../core/audio/audio_format_profile.dart';
import 'float64_fifo.dart';
import 'resampler.dart';

/// Alternative to [SpectralNoiseSuppressor] on the TX path: a
/// recurrent-network denoiser (RNNoise), which — unlike spectral subtraction
/// — was trained on non-stationary noise (wind, traffic) and doesn't need a
/// noise floor to "lock onto" first.
///
/// RNNoise only runs at 48 kHz in fixed 480-sample (10 ms) frames, so this
/// wraps it with an up/48k-process/down round trip: [txRateHz] stays the wire
/// format (bandwidth stays exactly as before), only the noise-reduction stage
/// itself runs at RNNoise's native rate — the same shape real call-processing
/// pipelines use, where the DSP/NN stage's internal rate is decoupled from
/// the codec's. Both [AudioFormatProfile.legacy16k] (48000/16000 = 3:1) and
/// [AudioFormatProfile.hd24k] (48000/24000 = 2:1) are exact ratios, so
/// there's no long-run sample-rate drift from the round trip at either.
///
/// [strength] 0 disables (pure passthrough); 1 uses RNNoise's output
/// unmixed. Intermediate values cross-fade dry/wet — RNNoise itself has no
/// native "strength" knob. Output is delayed relative to input by the
/// pipeline's startup latency (roughly one 480-sample RNNoise frame's worth
/// of [txRateHz]-equivalent samples); output length always equals input
/// length.
class RnnoiseSuppressor {
  /// [txRateHz] defaults to [AudioFormatProfile.legacy16k]'s rate — not a
  /// compile-time constant default (field access on a const object isn't a
  /// constant expression in Dart), so it's resolved here rather than inline.
  factory RnnoiseSuppressor({int? txRateHz}) => RnnoiseSuppressor._(
    txRateHz ?? AudioFormatProfile.legacy16k.sampleRateHz,
  );

  RnnoiseSuppressor._(int txRateHz)
    : _up = LinearResampler(
        inRate: txRateHz.toDouble(),
        outRate: _rnnRate.toDouble(),
      ),
      _down = LinearResampler(
        inRate: _rnnRate.toDouble(),
        outRate: txRateHz.toDouble(),
      );

  static const int _rnnRate = 48000;

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

  final LinearResampler _up;
  final LinearResampler _down;

  // Unboxed ring buffers — this path runs on every mic callback, and plain
  // growable lists here (boxed doubles + O(n) removeRange shifts) generated
  // enough garbage at audio rate to cause visible GC pauses.
  final Float64Fifo _rnnIn =
      Float64Fifo(); // 48 kHz, awaiting a full 480-sample frame
  final Float64Fifo _outTx =
      Float64Fifo(); // denoised at txRateHz, awaiting emission
  final Float64Fifo _dryTx =
      Float64Fifo(); // dry at txRateHz, paired with _outTx

  /// Process a block of any length; returns the same number of samples.
  List<double> process(List<double> samples) {
    final denoiser = _denoiser;
    if (strength <= 0.0 || denoiser == null) {
      if (_rnnIn.isNotEmpty || _outTx.isNotEmpty || _dryTx.isNotEmpty) {
        _clearBuffers();
      }
      return samples;
    }
    if (samples.isEmpty) return samples;

    _dryTx.addAll(samples);

    _rnnIn.addAll(_up.process(samples));
    final frameSize = denoiser.frameSize;
    while (_rnnIn.length >= frameSize) {
      final frame = Float32List(frameSize);
      for (var i = 0; i < frameSize; i++) {
        frame[i] = _rnnIn[i] * _pcmScale;
      }
      _rnnIn.discardFirst(frameSize);

      final (wetFrame, _) = denoiser.process(frame);
      final wetScaled = Float64List(frameSize);
      for (var i = 0; i < frameSize; i++) {
        wetScaled[i] = wetFrame[i] / _pcmScale;
      }
      _outTx.addAll(_down.process(wetScaled));
    }

    final take = min(_outTx.length, samples.length);
    final offset = samples.length - take; // > 0 only during startup latency
    final total = offset + take;
    final out = Float64List(samples.length);
    for (var i = 0; i < offset; i++) {
      out[i] = _dryTx[i]; // wet path hasn't produced output yet
    }
    for (var i = 0; i < take; i++) {
      final dry = _dryTx[offset + i];
      out[offset + i] = dry + (_outTx[i] - dry) * strength;
    }
    _dryTx.discardFirst(total);
    _outTx.discardFirst(take);
    return out;
  }

  void _clearBuffers() {
    _up.reset();
    _down.reset();
    _rnnIn.clear();
    _outTx.clear();
    _dryTx.clear();
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
