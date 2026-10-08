import 'dart:typed_data';

import 'src/rnnoise_stub.dart' if (dart.library.io) 'src/rnnoise_io.dart'
    as impl;

/// Real-time speech denoiser backed by RNNoise (native, via dart:ffi).
///
/// Stateless from the caller's perspective except for the internal RNN
/// hidden state carried across frames — always feed frames from one
/// continuous stream in order; don't share one instance across sessions
/// with unrelated audio (call [dispose] and create a fresh instance instead).
///
/// Unavailable on web (and any build where the native library hasn't been
/// compiled in) — [tryCreate] returns `null` there, never throws.
class RnnoiseDenoiser {
  RnnoiseDenoiser._(this._impl);

  final impl.RnnoiseImpl _impl;

  /// Number of samples [process] expects per call: 480 (10 ms @ 48 kHz mono).
  int get frameSize => _impl.frameSize;

  /// Attempts to create a denoiser. Returns `null` if the native library is
  /// unavailable on this platform/build — callers must treat RNNoise as
  /// optional and fall back accordingly.
  static RnnoiseDenoiser? tryCreate() {
    final created = impl.tryCreateRnnoiseImpl();
    if (created == null) return null;
    return RnnoiseDenoiser._(created);
  }

  /// Denoises exactly [frameSize] samples of 48 kHz mono float PCM, scaled to
  /// PCM16 magnitude (roughly [-32768, 32767] — NOT normalised [-1, 1];
  /// RNNoise was trained on int16 samples cast straight to float). Returns
  /// the denoised frame and the frame's voice-activity-detection probability
  /// (0..1, higher = more speech-like).
  (Float32List out, double vadProbability) process(Float32List frame) =>
      _impl.process(frame);

  /// Frees the native RNN state. Safe to call more than once.
  void dispose() => _impl.dispose();
}

/// Native streaming orchestration around the same RNNoise frame inference.
///
/// Accepts normalized samples at the transmission rate. Resampling, 480-sample
/// packing, PCM scaling and strength mixing happen in one native call per block.
/// Available only when all optional stream symbols are present; callers can
/// retain [RnnoiseDenoiser] and their existing orchestration as a fallback.
class RnnoiseStream {
  RnnoiseStream._(this._impl);

  final impl.RnnoiseStreamImpl _impl;

  static RnnoiseStream? tryCreate({required int sampleRateHz}) {
    final created = impl.tryCreateRnnoiseStreamImpl(sampleRateHz);
    return created == null ? null : RnnoiseStream._(created);
  }

  /// Returns exactly as many samples as supplied, including during startup.
  Float64List process(List<double> samples, {required double strength}) =>
      _impl.process(samples, strength);

  /// Clears both converter/FIFO and recurrent model state.
  void reset() => _impl.reset();

  /// Releases native state and buffers. Repeated calls are harmless; subsequent
  /// [process] and [reset] calls throw [StateError].
  void dispose() => _impl.dispose();
}
