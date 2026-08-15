/// Which algorithm cleans the mic signal on the TX path before VOX/transmit.
///
/// See SpectralNoiseSuppressor and RnnoiseSuppressor in
/// lib/feature/audio/domain/ for the two implementations — this enum is just
/// the persisted choice between them.
enum NoiseSuppressionEngine {
  /// No cleaning at all — the mic signal reaches VOX and the encoder exactly
  /// as the resampler produced it.
  ///
  /// This is not the same as dragging the strength slider to 0, even though
  /// both end up as passthrough today: this one is a stated preference that
  /// survives a strength change, and it is the only setting that stays off
  /// when someone later raises the slider again. It exists because every
  /// suppressor here trades intelligibility for quiet, and on a bad link
  /// (a moving motorcycle, a hotspot at the edge of its range) the audio is
  /// already being chewed by packet loss — a denoiser eating the consonants
  /// on top of that is what turns "hard to understand" into "unintelligible".
  /// Being able to take the whole stage out of the chain is the only way to
  /// find out whether it is the cleaner or the link doing the damage.
  off,

  /// Classic short-time spectral subtraction. Locks onto stationary noise
  /// (wind hiss, engine drone); pure Dart, works on every platform.
  spectral,

  /// RNNoise, a recurrent-network denoiser trained on non-stationary noise
  /// too. Native (dart:ffi) — only available where the platform build has
  /// compiled the library in (Android for now).
  rnnoise,

  /// Both in cascade: RNNoise first (non-stationary noise, needs the raw-ish
  /// mic signal it was trained on), then spectral subtraction to mop up any
  /// residual steady hum. Costs the battery of both; falls back to spectral
  /// alone where RNNoise isn't available.
  both;

  static NoiseSuppressionEngine fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => NoiseSuppressionEngine.rnnoise,
  );
}
