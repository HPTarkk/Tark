import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'rnnoise_bindings.dart';

/// One RNNoise denoiser instance (one native `DenoiseState`).
///
/// RNNoise processes exactly [frameSize] (480, i.e. 10 ms @ 48 kHz mono)
/// float samples per call — there is no variable-length API. The in/out
/// native buffers are allocated once and reused for the life of this
/// instance instead of malloc'd per frame, since this runs on every 10 ms
/// tick of the mic path.
class RnnoiseFFI {
  RnnoiseFFI._(this._bindings, this._state, this.frameSize)
    : _inBuf = malloc<Float>(frameSize),
      _outBuf = malloc<Float>(frameSize);

  /// Creates a denoiser with the library's built-in default model, or `null`
  /// if the native library can't be loaded (unsupported platform, missing
  /// binary) or allocation fails — callers should treat this as best-effort
  /// and fall back to bypass/another suppressor.
  static RnnoiseFFI? tryCreate() {
    try {
      final bindings = RnnoiseBindings();
      final frameSize = bindings.getFrameSize();
      final state = bindings.create(nullptr);
      if (state == nullptr) return null;
      return RnnoiseFFI._(bindings, state, frameSize);
    } catch (_) {
      return null;
    }
  }

  final RnnoiseBindings _bindings;
  final Pointer<DenoiseState> _state;
  final int frameSize;

  final Pointer<Float> _inBuf;
  final Pointer<Float> _outBuf;
  bool _disposed = false;

  /// Denoises exactly [frameSize] samples in [input]. RNNoise was trained on
  /// PCM16-scale magnitude (roughly [-32768, 32767], NOT normalised [-1, 1]
  /// float) — the reference `rnnoise_demo` feeds it int16 samples cast
  /// straight to float with no scaling, so callers using normalised floats
  /// must multiply by 32768 going in and divide coming out. Returns the
  /// denoised frame and the frame's voice-activity-detection probability
  /// (0..1).
  (Float32List out, double vadProbability) processFrame(Float32List input) {
    assert(input.length == frameSize);
    _inBuf.asTypedList(frameSize).setAll(0, input);
    final vad = _bindings.processFrame(_state, _outBuf, _inBuf);
    final out = Float32List.fromList(_outBuf.asTypedList(frameSize));
    return (out, vad);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.destroy(_state);
    malloc.free(_inBuf);
    malloc.free(_outBuf);
  }
}
