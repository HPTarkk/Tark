import 'opus_tuner.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../entity/opus_tuning.dart';
import 'media_receiver_feedback_session.dart';

/// Turns measured link conditions into encoder settings for a #29 HD Shared
/// Music stream — [OpusTuner]'s sibling, not a branch inside it.
///
/// The sender-side loss/RTT ladder remains pure; #41 applies the current
/// receiver-driven room-floor as a ceiling to that ladder. The optional
/// [receiverBitrateCapKbpsOverride] is a deterministic test seam only — live
/// callers leave it null and consume the session decision.
class MediaOpusTuner {
  const MediaOpusTuner({this.receiverBitrateCapKbpsOverride});

  final int? receiverBitrateCapKbpsOverride;

  factory MediaOpusTuner.forProfile(AudioFormatProfile profile) {
    assert(
      profile.kind == AudioProfileKind.media,
      'MediaOpusTuner is for media profiles; $profile is not one',
    );
    return const MediaOpusTuner();
  }

  static const initial = OpusTuning(
    bitrate: 64000,
    packetLossPerc: 0,
    complexity: 6,
  );

  static const maxLossPerc = OpusTuner.maxLossPerc;
  static const congestedRtt = OpusTuner.congestedRtt;
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
