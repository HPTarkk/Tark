/// Which algorithm cleans the mic signal on the TX path before VOX/transmit.
///
/// See SpectralNoiseSuppressor and RnnoiseSuppressor in
/// lib/feature/audio/domain/ for the two implementations — this enum is just
/// the persisted choice between them.
enum NoiseSuppressionEngine {
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
