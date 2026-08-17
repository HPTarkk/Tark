import 'dart:math';

import '../../../core/settings/vox_margin.dart';

/// Tracks the ambient noise level so the VOX gate can sit a fixed distance
/// above it.
///
/// A fixed VOX threshold is tuned once and then wrong for most of a ride. Set
/// it in a quiet room and a highway's wind noise holds the channel open
/// permanently — the rider transmits nothing but noise and never notices,
/// because nothing on their own phone says so. Set it for the highway and the
/// same phone clips the front off every sentence indoors.
///
/// The level that separates the two is not an absolute number, it is a distance
/// *above the background*. This measures the background; [VoxMargin] is the
/// distance, and it is now what the slider stores.
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

  /// The quietest background the gate will believe, ≈ −54 dBFS.
  ///
  /// **The hazard the pure-margin reframe introduced, and the one thing that
  /// has to hold it off.** A margin is a multiplication, and a multiplication
  /// by a floor of zero is zero — which `VoxGate` reads as *off*. That is not
  /// hypothetical: the platform noise suppressor on some phones hands back
  /// frames of exact digital silence between words (measured on a Galaxy S8+,
  /// 301 of 800 frames in a 15 s window — see [VoxGate] for the report it
  /// generated). Those zeros drag the estimate down at [_alphaDown], and within
  /// a second or two of quiet the gate would disarm itself on precisely the
  /// devices whose mics behave worst. The old absolute slider hid this, because
  /// the user's own number sat underneath as a floor; a pure margin has nothing
  /// underneath, so it needs this.
  ///
  /// Low enough to be under any real acoustic background, so it never raises
  /// the bar in a room someone is actually speaking in — it only refuses to
  /// believe silence.
  static const double _minFloor = 0.002;

  /// Ceiling on the resulting threshold. A mic fault that reports an enormous
  /// level must not be able to set a threshold no voice could ever cross —
  /// that would be a silently muted phone, which is the failure this whole area
  /// exists to avoid. Better to transmit noise than to be inaudible and not
  /// know it.
  static const double _maxThreshold = 0.15;

  double? _floor;

  /// Current estimate of the ambient level, or null before the first frame.
  /// Reported unclamped — [_minFloor] applies to the threshold, not to the
  /// measurement, so a diagnostic line still says what the mic actually did.
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

  /// The absolute level the VOX gate should compare frames against, given how
  /// far above the room the user asked to be.
  ///
  /// [margin] is the slider's value on [VoxMargin]'s scale, and its contract at
  /// zero is preserved exactly: **zero still means VOX off**, and this returns
  /// zero unchanged so [VoxGate] takes its "never hold anything back" path.
  ///
  /// Before any frame has been observed there is no background to measure
  /// against, and this returns 0 — open. Failing open is the only safe
  /// direction here: the cost of guessing high for the fraction of a second
  /// before the first frame lands is a clipped word, and the cost of guessing
  /// it wrong for longer is a phone that is quietly mute.
  double thresholdFor(double margin) {
    if (VoxMargin.isOff(margin)) return 0.0;
    final floor = _floor;
    if (floor == null) return 0.0;
    final base = max(floor, _minFloor);
    return (base * VoxMargin.multiplierFor(margin)).clamp(0.0, _maxThreshold);
  }

  /// Forgets the estimate — call when the capture session restarts, since the
  /// level it describes belonged to a different mic route.
  void reset() => _floor = null;
}
