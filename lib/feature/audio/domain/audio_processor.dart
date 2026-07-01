import 'dart:math';

/// Real-time audio processor applied to captured mic samples before TX.
///
/// Chain (in order):
///   1. Normalization       – converts any integer-range input to [-1, 1]
///   2. High-pass IIR       – removes DC offset + hum below ~80 Hz
///   3. Envelope noise gate – attenuates the noise floor under speech
///
/// Step 3 is deliberately a per-sample envelope follower, not a per-block
/// gate. An earlier version gated whole ~10 ms blocks based on their average
/// RMS, which chopped into word onsets/consonants whenever a block's average
/// dipped near the threshold mid-word, making speech sound muffled/robotic.
/// A fast-attack/slow-release envelope follower opens instantly on any
/// transient and closes gradually, so it suppresses steady hiss between/
/// under words without audibly gating the speech itself. The threshold is
/// also well below the VOX threshold in [WalkieTalkieCubit], so it only
/// trims residual noise inside frames VOX already decided are "talking" —
/// it does not duplicate VOX's job.
class AudioProcessor {
  /// Sample rate the filter was designed for. Pass the rate samples are
  /// actually processed at so the time constants below are recalculated
  /// correctly.
  AudioProcessor({
    double sampleRate = 16000.0,
    this.gateThreshold = 0.012,
    this.gateRatio = 6.0,
  }) {
    // α for a first-order high-pass: α = 1 / (1 + 2π·fc/fs)
    // fc ≈ 80 Hz gives a pole well below the voice band (80–3500 Hz)
    const fc = 80.0;
    _hpAlpha = 1.0 / (1.0 + 2 * pi * fc / sampleRate);

    // Envelope follower attack/release coefficients (1 - e^(-1/(fs*tau))).
    _envAttack = 1.0 - exp(-1.0 / (sampleRate * 0.003)); // 3 ms — catch onsets fast
    _envRelease = 1.0 - exp(-1.0 / (sampleRate * 0.12)); // 120 ms — close gradually
  }

  /// Gate opens above this RMS-equivalent envelope level (normalised scale).
  /// Mutable so the caller can tie it to the user's VOX threshold setting —
  /// in particular, setting this to 0 disables the gate entirely (gain is
  /// always 1.0), which is required for a VOX threshold of "0 = always on"
  /// to actually mean no gating anywhere in the chain.
  double gateThreshold;

  /// Attenuation factor below the gate (e.g. 6 ≈ −15.6 dB).
  final double gateRatio;

  // High-pass filter state
  late final double _hpAlpha;
  double _hpY = 0.0; // previous output
  double _hpX = 0.0; // previous input

  // Envelope follower state
  late final double _envAttack;
  late final double _envRelease;
  double _envelope = 0.0;

  // Input-range detection (auto-detects integer vs float input)
  double _maxSeenAbs = 0.0;
  bool _calibrated = false;
  static const _calibrationFrames = 50;
  int _frameCount = 0;

  /// Process one block of microphone samples.
  /// Returns a new list of normalised, filtered, noise-gated samples.
  List<double> process(List<double> samples) {
    if (samples.isEmpty) return samples;

    _detectRange(samples);

    final scale = _calibrated && _maxSeenAbs > 1.0 ? 1.0 / _maxSeenAbs : 1.0;

    final out = List<double>.filled(samples.length, 0.0);

    for (int i = 0; i < samples.length; i++) {
      // 1. Normalise
      final x = (samples[i] * scale).clamp(-1.0, 1.0);

      // 2. High-pass IIR: y[n] = α·(y[n-1] + x[n] - x[n-1])
      final y = _hpAlpha * (_hpY + x - _hpX);
      _hpX = x;
      _hpY = y;

      // 3. Envelope follower (fast attack, slow release) + soft expander.
      final absY = y.abs();
      final coeff = absY > _envelope ? _envAttack : _envRelease;
      _envelope += coeff * (absY - _envelope);

      double gain = 1.0;
      if (gateThreshold > 0.0 && _envelope < gateThreshold) {
        final below = _envelope / gateThreshold; // 0..1
        // Smoothly interpolate gain between full attenuation (1/gateRatio)
        // at silence and unity gain at the threshold, instead of a hard cut.
        gain = (1.0 / gateRatio) + below * (1.0 - 1.0 / gateRatio);
      }

      out[i] = y * gain;
    }

    return out;
  }

  void _detectRange(List<double> samples) {
    if (_calibrated) return;
    for (final s in samples) {
      final abs = s.abs();
      if (abs > _maxSeenAbs) _maxSeenAbs = abs;
    }
    _frameCount++;
    if (_frameCount >= _calibrationFrames) {
      _calibrated = true;
    }
  }

  void reset() {
    _hpY = 0.0;
    _hpX = 0.0;
    _envelope = 0.0;
    _maxSeenAbs = 0.0;
    _calibrated = false;
    _frameCount = 0;
  }
}
