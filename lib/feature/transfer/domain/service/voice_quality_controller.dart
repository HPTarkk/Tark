import '../../../../core/audio/audio_format_profile.dart';
import 'adaptive_tier_gate.dart';
import 'opus_tuner.dart';

/// #32 — the "should voice be running HD right now" decision, hysteresis-
/// gated and separate from [OpusTuner]'s per-tick bitrate/complexity/FEC
/// tuning (which stays fast and flap-tolerant by design — see that class's
/// own "why there is no hysteresis" doc). This is the slow half: whether the
/// negotiated *sample rate* itself should be running at HD right now, given
/// a sustained trend rather than one measurement — [AudioCapabilityNegotiator]
/// only ever answers "can both builds decode HD," never "should we, given
/// how this link is actually behaving."
///
/// Wraps [AdaptiveTierGate] with voice's own two tiers
/// ([AudioFormatProfile.legacy16k], [AudioFormatProfile.hd24k]) and voice's
/// own thresholds — starting figures, not a final listening-validated
/// tuning, same caveat every ladder in this neighbourhood carries; see #28's
/// physical motorcycle A/B requirement before treating these as settled.
/// Can never fall below [AudioFormatProfile.legacy16k]: that tier is the
/// reliable floor the roadmap requires stays production-usable regardless of
/// how poor the link gets.
class VoiceQualityController {
  VoiceQualityController({
    int downgradeEvidenceMs = 4000,
    int upgradeCleanMs = 15000,
    int minDwellMs = 5000,
  }) : _gate = AdaptiveTierGate<AudioFormatProfile>(
         tiers: const [AudioFormatProfile.legacy16k, AudioFormatProfile.hd24k],
         downgradeEvidenceMs: downgradeEvidenceMs,
         upgradeCleanMs: upgradeCleanMs,
         minDwellMs: minDwellMs,
       );

  final AdaptiveTierGate<AudioFormatProfile> _gate;

  /// The profile this controller currently allows. The *effective* wire
  /// profile is never this alone — callers must still intersect it with
  /// [AudioCapabilityNegotiator.resolve]'s ceiling, which [advance] already
  /// enforces going forward, but a caller reading [profile] before the first
  /// [advance] call sees only this controller's own starting tier.
  AudioFormatProfile get profile => _gate.tier;

  /// Loss bar past which HD is considered unsustainable — the same bar
  /// [OpusTuner.hd]'s own worst bitrate/complexity tier already treats as
  /// "as bad as HD gets to run," so there is nothing left for the fast path
  /// to give up before the slow path should consider a narrower, cheaper
  /// signal instead. See [OpusTuner.maxLossPerc].
  static const _poorLossPerc = 15;

  /// Loss bar an upgrade requires — deliberately far stricter than "not
  /// poor": an upgrade should be justified by conditions good enough that
  /// the fast path is already running its best tier, not merely by the
  /// absence of trouble.
  static const _cleanLossPerc = 2;

  static const _congestedRtt = OpusTuner.congestedRtt;

  /// [conditions] is the same evidence [OpusTuner.tune] already receives —
  /// far-end loss and RTT in the direction our voice travels, never our own
  /// receive statistics (see [AudioLinkConditions]'s own doc for why).
  /// [ceiling] is whatever [AudioCapabilityNegotiator.resolve] currently
  /// allows; [profile] can never exceed it. [elapsedMs] is real time since
  /// the last call — callers on an irregular tick (a presence timer, not an
  /// audio frame clock) pass however long it's actually been.
  TierTransition<AudioFormatProfile>? advance({
    required AudioLinkConditions conditions,
    required AudioFormatProfile ceiling,
    required int elapsedMs,
  }) {
    final lossPerc = (conditions.lossFraction * 100).ceil();
    final rtt = conditions.rtt;
    final congested = rtt != null && rtt > _congestedRtt;

    return _gate.advance(
      conditionsSupportCurrentTier: lossPerc < _poorLossPerc && !congested,
      conditionsSupportNextTier: lossPerc < _cleanLossPerc && !congested,
      ceilingIndex: _indexOf(ceiling),
      elapsedMs: elapsedMs,
    );
  }

  static int _indexOf(AudioFormatProfile ceiling) =>
      ceiling == AudioFormatProfile.hd24k ? 1 : 0;

  /// Resets to [AudioFormatProfile.legacy16k] with no transition event —
  /// call on a new session, the same way a fresh [AudioCapabilityNegotiator]
  /// starts every session not knowing anything about the new roster yet.
  void reset() => _gate.reset(0);
}
