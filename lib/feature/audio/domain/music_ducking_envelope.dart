import 'dart:math';

/// Deterministic, centralized gain envelope for Smart Music Ducking (#31).
///
/// Callers advance this once per media frame with a single boolean —
/// "is voice active right now" — already resolved from whatever mix of
/// signals matters (remote peer speaking, local VOX gate open, overlapping
/// speakers). This class knows nothing about roster state, VOX, or audio
/// packets; it only turns that boolean into a click-free multiplicative gain
/// on top of the user's own music volume, which is exactly the "temporary
/// multiplicative envelope on top of the base gain" #31 asks for. Multiply
/// [gain] onto samples that have already had [PlaybackGain]/the user's music
/// gain applied — never the other way around, or a duck would silently
/// change the user's remembered volume.
///
/// ## Why hangover is separate from release
///
/// A gap between two words is not "speech ended" — without a hold, every
/// syllable boundary would start the (slow) release ramp and then reverse it
/// on the next syllable, which is audible pumping. [hangoverMs] keeps the
/// target pinned at [duckTarget] for a while after voice activity drops out;
/// only once the hold itself elapses does the envelope start ramping back
/// toward 1.0 along [releaseMs]. Re-triggering voice activity at any point —
/// including mid-release — simply re-arms the hold and reverses the ramp
/// back toward [duckTarget], the same re-trigger behaviour [VoxGate] uses
/// for its own hangover.
///
/// ## Why linear, not exponential
///
/// An exponential follower never actually reaches its target, which makes
/// "did we finish ducking" a threshold judgement call rather than a fact.
/// A fixed-rate linear ramp reaches [duckTarget] (or 1.0) exactly, in a
/// duration callers can predict from [attackMs]/[releaseMs] alone, and is
/// just as click-free as long as it is advanced every frame — which callers
/// on a periodic media clock ([MediaFrameScheduler]) always do.
class MusicDuckingEnvelope {
  MusicDuckingEnvelope({
    this.duckTarget = 0.3,
    this.attackMs = 120,
    this.releaseMs = 800,
    this.hangoverMs = 400,
  }) : assert(duckTarget >= 0.0 && duckTarget <= 1.0),
       assert(attackMs > 0),
       assert(releaseMs > 0),
       assert(hangoverMs >= 0);

  /// Gain floor while fully ducked — a fraction of the user's own music
  /// gain, never an absolute level. 0.3 sits in #31's "~25-35%" starting
  /// range.
  final double duckTarget;

  /// Time to ramp from 1.0 down to [duckTarget] once voice activity starts.
  final int attackMs;

  /// Time to ramp from [duckTarget] back up to 1.0 once the hold in
  /// [hangoverMs] has elapsed with no voice activity.
  final int releaseMs;

  /// How long the target stays pinned at [duckTarget] after voice activity
  /// last reported active, so short gaps between words don't start (and
  /// immediately reverse) the release ramp.
  final int hangoverMs;

  double _gain = 1.0;
  int _hangoverRemainingMs = 0;

  /// Current linear gain, always in `[duckTarget, 1.0]`. Multiply this onto
  /// already-volume-adjusted music samples.
  double get gain => _gain;

  /// Whether the envelope is anywhere below full volume — ducked, ducking,
  /// or recovering. Distinct from "voice is active": the hold and release
  /// ramp both keep this true after voice activity itself has stopped.
  bool get isDucked => _gain < 1.0;

  /// Advances the envelope by one frame of [frameDurationMs] given whether
  /// voice is active this frame, and returns the resulting [gain].
  double advance({required bool voiceActive, required int frameDurationMs}) {
    if (voiceActive) {
      _hangoverRemainingMs = hangoverMs;
    } else if (_hangoverRemainingMs > 0) {
      _hangoverRemainingMs = max(0, _hangoverRemainingMs - frameDurationMs);
    }

    final target = (voiceActive || _hangoverRemainingMs > 0)
        ? duckTarget
        : 1.0;

    if (_gain == target) return _gain;

    final rampMs = target < _gain ? attackMs : releaseMs;
    final step = frameDurationMs / rampMs;
    _gain = target < _gain
        ? max(target, _gain - step)
        : min(target, _gain + step);
    return _gain;
  }

  /// Returns to full volume immediately with no ramp and clears the hold —
  /// call on music stop/start or a channel reset so a stale duck can never
  /// survive into a new cast. See #31's "reconnect/media-stop can't leave
  /// music stuck ducked" invariant.
  void reset() {
    _gain = 1.0;
    _hangoverRemainingMs = 0;
  }
}
