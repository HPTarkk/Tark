import 'adaptive_tier_gate.dart';
import 'media_opus_tuner.dart';
import 'media_receiver_feedback_session.dart';
import 'opus_tuner.dart';

/// Whether a #29 media stream should keep transmitting right now.
///
/// [MediaOpusTuner] already covers "media policy from #29's tiers" — its own
/// fast, hysteresis-free ladder from 96 down to 32 kbps. What it deliberately
/// has no opinion on (see [MediaOpusTuner.hdFloorBitrate]'s doc: "the product
/// should prefer to degrade **or pause**") is the last resort past that
/// ladder's own worst tier: a link so consistently bad that continuing to
/// spend airtime on media pressures voice/control for a stream whose entire
/// purpose is enjoyment, not safety. [MediaSendTier.active] is every
/// operating point [MediaOpusTuner]'s ladder already handles, including its
/// 32 kbps floor; [MediaSendTier.suspended] is this controller's own
/// addition, one rung further down.
enum MediaSendTier { suspended, active }

/// #32 — the slow, hysteresis-gated "should media transmission continue at
/// all" decision, kept separate from [MediaOpusTuner]'s per-tick bitrate/
/// complexity tuning for the same reason [VoiceQualityController] is kept
/// separate from [OpusTuner]: flipping media on and off is an audible,
/// disruptive event (losing a song entirely, not merely hearing it get
/// quieter) that deserves sustained evidence and a cooldown, not a snap
/// reaction to one bad sample. Wraps [AdaptiveTierGate] the same way
/// [VoiceQualityController] does, but unlike voice this has no peer-capability
/// ceiling to enforce — [AudioCapabilityNegotiator]'s media list already gates
/// whether a media stream can start at all; this only ever asks whether an
/// already-running stream should keep going.
///
/// Starting figures, not a final listening-validated tuning — same caveat
/// every ladder in this neighbourhood carries. Deliberately more conservative
/// than [VoiceQualityController]'s: suspending music is worse UX than briefly
/// running it at 32 kbps, so both the evidence required to suspend and the
/// evidence required to resume are longer than voice's HD/legacy windows.
class MediaQualityController {
  MediaQualityController({
    int downgradeEvidenceMs = 8000,
    int upgradeCleanMs = 20000,
    int minDwellMs = 8000,
    MediaReceiverFeedbackSession? receiverFeedback,
  }) : _gate = AdaptiveTierGate<MediaSendTier>(
         tiers: const [MediaSendTier.suspended, MediaSendTier.active],
         downgradeEvidenceMs: downgradeEvidenceMs,
         upgradeCleanMs: upgradeCleanMs,
         minDwellMs: minDwellMs,
         // Starting a media stream is already a deliberate user action (Music
         // Cast start) — this controller's default posture is "let it run"
         // until conditions prove otherwise, not "earn the right to start"
         // the way voice earns HD.
         initialIndex: 1,
       ),
       _receiverFeedback =
           receiverFeedback ?? MediaReceiverFeedbackSession.shared;

  final AdaptiveTierGate<MediaSendTier> _gate;
  final MediaReceiverFeedbackSession _receiverFeedback;

  /// The tier this sender-side controller currently allows.
  MediaSendTier get tier => _gate.tier;

  /// Media must pass both the legacy sender-side congestion gate and #41's
  /// receiver-driven room-floor decision. Receiver distress wins immediately
  /// so voice/control is protected even while the slower sender-side gate is
  /// still accumulating evidence.
  bool get shouldSend =>
      tier == MediaSendTier.active && _receiverFeedback.decision.shouldTransmit;

  /// Same ceiling [MediaOpusTuner.maxLossPerc] uses — past this,
  /// [MediaOpusTuner]'s own ladder is already at its worst tier with nothing
  /// left to give up, so sustained loss beyond it is this controller's signal
  /// to suspend rather than keep spending airtime on a stream that can't be
  /// helped further.
  static const _failingLossPerc = MediaOpusTuner.maxLossPerc;

  /// Loss bar a resume requires — [MediaOpusTuner.tune]'s own "normal HD"
  /// bracket boundary, not merely "no longer failing." Resuming only to
  /// suspend again moments later is worse than staying suspended a little
  /// longer.
  static const _resumeLossPerc = 8;

  static const _congestedRtt = MediaOpusTuner.congestedRtt;

  /// [conditions] is the same evidence [MediaOpusTuner.tune] already
  /// receives. [elapsedMs] is real time since the last call — callers on an
  /// irregular tick pass however long it's actually been.
  TierTransition<MediaSendTier>? advance({
    required AudioLinkConditions conditions,
    required int elapsedMs,
  }) {
    _receiverFeedback.evaluate(DateTime.now(), elapsedMs);

    final lossPerc = (conditions.lossFraction * 100).ceil();
    final rtt = conditions.rtt;
    final congested = rtt != null && rtt > _congestedRtt;

    return _gate.advance(
      conditionsSupportCurrentTier: lossPerc < _failingLossPerc,
      // No congestion-alone suspend: MediaOpusTuner already backs bitrate off
      // under congestion without needing to stop transmitting, and voice's
      // own congestion sensitivity already protects voice independently — see
      // VoiceQualityController.advance. A clean resume, however, does require
      // an uncongested link: resuming only to suspend again is worse UX.
      conditionsSupportNextTier: lossPerc < _resumeLossPerc && !congested,
      ceilingIndex: MediaSendTier.values.length - 1,
      elapsedMs: elapsedMs,
    );
  }

  /// Resets both sender-side and receiver-side session evidence. A new media
  /// stream/session must not inherit distress or confirmation from an old one.
  void reset() {
    _gate.reset(1);
    _receiverFeedback.reset();
  }
}
