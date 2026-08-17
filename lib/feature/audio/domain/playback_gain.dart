import 'dart:typed_data';

/// Applies a linear gain to received voice, soft-limited so a boost can never
/// clip.
///
/// ## Why not just multiply and clamp
///
/// The only reason to raise playback gain here is that the listener is a rider
/// competing with road noise, and the thing that survives road noise is
/// *intelligibility*, not level. Hard-clamping a boosted signal to ±1.0
/// flattens every peak into a straight line, which is square-wave distortion
/// spread right across the band the consonants live in — measurably louder and
/// noticeably harder to understand. That is the same trap as over-suppression,
/// arriving from the other direction.
///
/// So above [_knee] the remaining headroom is compressed asymptotically: the
/// output approaches 1.0 without ever reaching it, and the curve is continuous
/// in both value and slope at the knee, so quiet speech passes through with
/// literally no change and loud speech bends rather than breaks.
///
/// Pure and allocation-free at unity, so the RX hot path pays nothing for the
/// feature being available.
class PlaybackGain {
  /// Level above which the soft limiter starts to bend the signal. Below it,
  /// output is exactly `input × gain`.
  static const double _knee = 0.7;

  double _gain = 1.0;

  /// Linear gain. 1.0 disables the whole stage — [apply] then returns its
  /// argument untouched, with no allocation and no arithmetic.
  double get gain => _gain;

  set gain(double value) {
    // A negative gain would invert the waveform, and an enormous one would put
    // every sample against the limiter and turn speech into a flat buzz. This
    // is fed from a preset constant today, but it is the kind of value a
    // future slider hands over, so the clamp lives with the maths.
    _gain = value.isNaN ? 1.0 : value.clamp(0.0, 4.0);
  }

  /// Returns [samples] scaled by [gain]. At unity this is the identical list —
  /// callers must therefore treat the result as read-only, exactly as they
  /// already do for the resampler's pass-through.
  List<double> apply(List<double> samples) {
    if (_gain == 1.0 || samples.isEmpty) return samples;
    final out = Float64List(samples.length);
    for (int i = 0; i < samples.length; i++) {
      out[i] = _limit(samples[i] * _gain);
    }
    return out;
  }

  /// Soft knee: identity below [_knee], asymptotic to ±1.0 above it.
  static double _limit(double x) {
    final a = x.abs();
    if (a <= _knee) return x;
    const headroom = 1.0 - _knee;
    final over = a - _knee;
    // over = 0        -> knee            (continuous with the identity branch)
    // over -> infinity-> knee + headroom = 1.0
    // d/dover at 0    -> 1               (slope continuous too)
    final limited = _knee + headroom * (over / (over + headroom));
    return x < 0 ? -limited : limited;
  }
}
