import 'opus_tuner.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../entity/opus_tuning.dart';
import 'media_receiver_feedback_session.dart';

/// Turns measured link conditions into encoder settings for a #29 HD Shared
/// Music stream — [OpusTuner]'s sibling, not a branch inside it.
///
/// [OpusTuner]'s tiers, complexity, and its "why no hysteresis" reasoning are
/// all built around speech (see that class's doc): a link losing a quarter of
/// its datagrams gets Opus down to 12 kbps because *intelligible* is the bar
/// for voice. That bar is wrong for music — 12 kbps stereo music is not
/// "degraded HD," it should stop calling itself HD at all — so #29 gets its
/// own ladder rather than a special case bolted onto the voice one.
///
/// Same non-hysteresis reasoning as [OpusTuner] applies here unchanged:
/// `OPUS_SET_BITRATE` is cheap and absorbing a few-kbps step is what the
/// encoder is built for, so no state machine is needed to avoid an audible
/// flap.
///
/// The bitrates below are starting engineering targets, exactly like
/// [OpusTuner.hd] was for #28 — not a final, listening-validated ladder. See
/// #29's physical A/B requirement before treating these as settled.
///
/// #41 keeps that sender-side ladder pure, then applies the current
/// receiver-driven room floor as a ceiling. [receiverBitrateCapKbpsOverride]
/// is only a deterministic test seam; live callers leave it null.
class MediaOpusTuner {
  const MediaOpusTuner({this.receiverBitrateCapKbpsOverride});

  final int? receiverBitrateCapKbpsOverride;

  /// [profile]'s tuner. Every #29 media profile shares one ladder today —
  /// this factory exists so a future profile-specific ladder (e.g. a
  /// bandwidth-constrained transport tier) is a call-site-free addition, the
  /// same role [OpusTuner.forProfile] plays for voice.
  factory MediaOpusTuner.forProfile(AudioFormatProfile profile) {
    assert(
      profile.kind == AudioProfileKind.media,
      'MediaOpusTuner is for media profiles; $profile is not one',
    );
    return const MediaOpusTuner();
  }

  /// What a link with no measurements gets. Media only ever starts once a
  /// channel already exists (voice has already measured the link by then),
  /// so this is deliberately conservative rather than optimistic — an
  /// unmeasured link should not open at the top tier.
  static const initial = OpusTuning(
    bitrate: 64000,
    packetLossPerc: 0,
    complexity: 6,
  );

  /// Same ceiling [OpusTuner.maxLossPerc] uses, for the same reason: past a
  /// quarter of the link lost, redundancy stops helping and it's the recovery
  /// ladder's problem, not the codec's.
  static const maxLossPerc = OpusTuner.maxLossPerc;

  /// Same congestion threshold as [OpusTuner.congestedRtt] — one link, so one
  /// definition of "congested" for whatever is sharing it.
  static const congestedRtt = OpusTuner.congestedRtt;

  /// Bitrate below which the product should prefer to degrade or pause media
  /// rather than keep calling the result "HD" — required by #29's acceptance
  /// criteria ("never call 12-20 kbps HD"). Callers building a Preflight- or
  /// UI-facing "is this still HD" signal should compare against this rather
  /// than re-deriving it.
  static const hdFloorBitrate = 48000;

  OpusTuning tune(AudioLinkConditions conditions) {
    final lossPerc = (conditions.lossFraction * 100).ceil().clamp(
      0,
      maxLossPerc,
    );

    final rtt = conditions.rtt;
    final congested = rtt != null && rtt > congestedRtt;

    final (senderBitrate, complexity) = switch (lossPerc) {
      < 2 when !congested => (96000, 8),
      < 8 => (64000, 7),
      < 15 => (48000, 6),
      _ => (32000, 5),
    };

    final receiverCap =
        (receiverBitrateCapKbpsOverride ??
            MediaReceiverFeedbackSession.shared.decision.targetBitrateKbps) *
        1000;
    // `suspended` is enforced by MediaQualityController.shouldSend. Keep a
    // valid Opus bitrate configured underneath it so resume never requires a
    // zero-bitrate encoder transition.
    final effectiveCap = receiverCap <= 0 ? 32000 : receiverCap;
    final bitrate = senderBitrate < effectiveCap ? senderBitrate : effectiveCap;

    return OpusTuning(
      bitrate: bitrate,
      packetLossPerc: lossPerc,
      complexity: complexity,
    );
  }
}
