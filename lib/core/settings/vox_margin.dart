import 'dart:math';

/// The VOX slider's scale, after it stopped being an absolute level.
///
/// ## What changed and why
///
/// The slider used to store an absolute RMS (0 – [legacyMax]) and
/// `NoiseFloorTracker` returned `max(thatValue, floor × 2.5)`. Two settings in
/// one control, and the wrong one usually won: a stored value above roughly
/// 0.06 is larger than `floor × 2.5` in any room quiet enough to hold a
/// conversation, so for everyone who dragged the slider up — the people who
/// found the gate too twitchy, i.e. exactly the people the adaptation was
/// written for — the measured background was never consulted at all. The
/// adaptation only ever reached users who had left the slider low.
///
/// The level that separates a voice from a room is not an absolute number, it
/// is a *distance above the background*. So that is what the slider stores now:
/// **how much louder than the room you have to be**, in dB, and the measured
/// floor supplies the rest. One setting that means the same thing in a parked
/// car and at 100 km/h, which is what the control was always trying to say.
///
/// ## The contract that did not change
///
/// **Zero still means VOX off.** Not "off is the most sensitive setting" — off,
/// as in nothing the mic hands over is ever withheld. It is deliberately not a
/// point on the dB scale below: [decibelsFor] and [multiplierFor] describe an
/// *armed* gate, and callers must ask [isOff] first. `VoxGate.advance` takes the
/// same shape (`threshold <= 0` short-circuits before any comparison), and
/// `NoiseFloorTracker.thresholdFor` is what joins the two.
abstract final class VoxMargin {
  /// VOX off. Preserved as 0.0 through the migration below, so an install that
  /// never armed the gate cannot be armed by an app update.
  static const double off = 0.0;

  /// The armed range, in dB above the measured background.
  ///
  /// 3 dB is nearly nothing — the instantaneous level of a steady background
  /// wanders by about that much on its own, so the bottom of the slider is a
  /// gate that trips easily, which is what the quiet end should mean. 18 dB is
  /// roughly eight times the background in amplitude: trivially cleared indoors,
  /// and real projection in a loud place.
  ///
  /// The fixed 2.5× (≈ 8 dB) this replaces sits at [marginForDecibels] ≈ 0.33,
  /// so the behaviour everyone has been running lands a third of the way up
  /// rather than at an end — there is room to go both ways from it.
  static const double minDb = 3.0;
  static const double maxDb = 18.0;

  /// The old slider's full-scale absolute RMS. Frozen: it is only ever used to
  /// read values written by builds that predate the reframe.
  static const double legacyMax = 0.15;

  static bool isOff(double margin) => margin <= off;

  /// The armed margin in dB. Meaningless when [isOff] — see the class doc.
  static double decibelsFor(double margin) {
    if (isOff(margin)) return 0.0;
    return minDb + (maxDb - minDb) * margin.clamp(0.0, 1.0);
  }

  /// Inverse of [decibelsFor], for placing a known dB figure on the slider.
  static double marginForDecibels(double db) =>
      ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

  /// How many times the measured background a frame must reach. 1.0 when off,
  /// which is not a gate setting — callers check [isOff] first.
  static double multiplierFor(double margin) =>
      pow(10.0, decibelsFor(margin) / 20.0).toDouble();

  /// Reads a value stored by a build that predates the reframe.
  ///
  /// **The number on the slider does not move; what it controls does.** The old
  /// control ran 0 – [legacyMax] and drew itself as 0 – 100 %, so the honest
  /// conversion is the percentage the user was actually looking at: someone who
  /// left it at 60 % is still at 60 %, now meaning 12 dB above the room instead
  /// of an absolute 0.09. That is the best available answer, because the one
  /// thing needed to convert properly — how loud *their* room was — is precisely
  /// what the old setting never recorded.
  ///
  /// Off maps to off, exactly. An update must not arm a gate the user left
  /// disarmed.
  static double fromLegacyThreshold(double absolute) {
    if (absolute <= 0) return off;
    return (absolute / legacyMax).clamp(0.0, 1.0);
  }
}
