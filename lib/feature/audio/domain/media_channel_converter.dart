import 'dart:typed_data';

import 'resampler.dart';

/// Explicit, testable channel conversion for the #29 HD Shared Music path —
/// the primitive required-work item 5 asks for, so a negotiated-mono peer can
/// be fed from `SystemAudioCapture.hdFrames`' genuine 48 kHz stereo capture
/// without an implicit, untested downmix hiding inside a future wiring call
/// site (that wiring itself is #30's job — this class is the primitive it
/// will call).
///
/// Stateless: channel downmixing has no history across frames to carry, so
/// unlike [LinearResampler] there is nothing to reset on a route/format
/// change — every call is independent of the last.
abstract final class MediaChannelConverter {
  /// Downmixes interleaved stereo (L, R, L, R, ...) to mono by averaging each
  /// frame's two channels.
  ///
  /// An odd trailing sample — a truncated frame — is dropped rather than
  /// guessed at, so the caller always gets back exactly
  /// `interleavedStereo.length ~/ 2` samples.
  ///
  /// Averaging two samples already in `[-1, 1]` can never leave that range,
  /// so this never clips — see the test that asserts exactly that rather than
  /// defensively clamping a value that cannot occur.
  static List<double> downmixToMono(List<double> interleavedStereo) {
    final frames = interleavedStereo.length ~/ 2;
    final out = Float64List(frames);
    for (var i = 0; i < frames; i++) {
      out[i] = (interleavedStereo[i * 2] + interleavedStereo[i * 2 + 1]) * 0.5;
    }
    return out;
  }
}
