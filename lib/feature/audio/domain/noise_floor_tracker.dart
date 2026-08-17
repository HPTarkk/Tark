/// Tracks the ambient noise level so the VOX threshold can follow it.
///
/// A fixed VOX threshold is tuned once and then wrong for most of a ride. Set
/// it in a quiet room and a highway's wind noise holds the channel open
/// permanently — the rider transmits nothing but noise and never notices,
/// because nothing on their own phone says so. Set it for the highway and the
/// same phone clips the front off every sentence indoors.
///
/// The level that separates the two is not an absolute number, it is a distance
/// *above the background*. This measures the background.
///
/// ## Why the estimate moves down fast and up slowly
///
/// The floor has to settle onto the quiet parts of the signal while ignoring
/// the loud ones, and speech is the loud one. So a frame below the current
/// estimate pulls it down quickly ([_alphaDown]) — a genuine drop in background
/// noise is real information and should apply within a breath — while a frame
/// above it nudges it up only slightly ([_alphaUp]).
///
/// Asymmetry alone is not enough, though. Over a long sentence, hundreds of
/// consecutive loud frames would still creep the estimate up toward speech
/// level, raising the threshold until the gate closed on the speaker's own
/// voice mid-sentence. So frames that are clearly speech — more than
/// [_speechRatio] above the floor — are not allowed to move it at all. Only the
/// quiet and the merely-slightly-loud contribute.
///
/// Pure — no clock, no audio device — so the convergence behaviour can be
/// tested directly by feeding it a sequence of levels.
class NoiseFloorTracker {
  /// Pull toward a frame quieter than the current estimate. Fast: roughly a
  /// tenth of a second at 20 ms frames.
  static const double _alphaDown = 0.3;

  /// Pull toward a frame louder than the current estimate. Slow: the background
  /// getting genuinely louder is a change over seconds, not frames.
  static const double _alphaUp = 0.002;

  /// How far above the floor a frame has to be before it is read as speech
  /// rather than background, and excluded from the estimate entirely.
  static const double _speechRatio = 3.0;

  /// How far above the floor the gate opens — about 8 dB, which is comfortably
  /// clear of the background without demanding a shout.
  static const double _margin = 2.5;

  /// Ceiling on the adaptive threshold, matching the top of the VOX slider's
  /// own range. A mic fault that reports an enormous level must not be able to
  /// set a threshold no voice could ever cross — that would be a silently
  /// muted phone, which is the failure this whole area exists to avoid.
  static const double _maxThreshold = 0.15;

  double? _floor;

  /// Current estimate of the ambient level, or null before the first frame.
  double? get noiseFloor => _floor;

  /// Folds one frame's RMS into the estimate.
  void observe(double rms) {
    if (rms.isNaN || rms < 0) return;
    final floor = _floor;
    // The first frame is the estimate: starting from zero and creeping up at
    // [_alphaUp] would leave the floor far too low for the first several
    // seconds of every session, which is exactly when a rider is most likely to
    // be checking whether the channel works.
    if (floor == null) {
      _floor = rms;
      return;
    }
    if (rms < floor) {
      _floor = floor + _alphaDown * (rms - floor);
    } else if (rms < floor * _speechRatio) {
      _floor = floor + _alphaUp * (rms - floor);
    }
    // Anything louder is speech, and contributes nothing.
  }

  /// The threshold the VOX gate should actually use, given what the user asked
  /// for.
  ///
  /// [userThreshold] is the slider's value and its contract is preserved
  /// exactly: **zero still means VOX off**, and this returns zero unchanged so
  /// [VoxGate] takes its "never hold anything back" path. The slider's promise
  /// at 0 % is that nothing the mic hands over is withheld, and no amount of
  /// measured background may override that.
  ///
  /// Above zero, the result is never *below* what the user asked for. The
  /// slider is a statement about what they do not want transmitted, so this can
  /// raise the bar to clear a noisy background but never lower it past their
  /// own floor. Reframing the slider itself as a pure margin would be the
  /// fuller answer, and belongs with the riding preset that renames it.
  double thresholdFor(double userThreshold) {
    if (userThreshold <= 0) return 0.0;
    final floor = _floor;
    if (floor == null) return userThreshold;
    final adaptive = (floor * _margin).clamp(0.0, _maxThreshold);
    return adaptive > userThreshold ? adaptive : userThreshold;
  }

  /// Forgets the estimate — call when the capture session restarts, since the
  /// level it describes belonged to a different mic route.
  void reset() => _floor = null;
}
