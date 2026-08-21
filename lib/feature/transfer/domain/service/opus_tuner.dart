import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/transfer/domain/service/peer_loss_tracker.dart';

import '../../../../core/audio/audio_format_profile.dart';
import '../entity/opus_tuning.dart';

/// What the transmit path knows about the link it is encoding for.
///
/// Both fields describe the link *in the direction our voice travels*, which is
/// the only direction the encoder can do anything about. That is why loss here
/// is the **far end's** loss and not ours: our own receive statistics describe
/// the peer's encoder, and tuning our encoder from them would have each phone
/// react to the other's problem.
class AudioLinkConditions {
  const AudioLinkConditions({this.lossFraction = 0.0, this.rtt});

  /// Fraction (0.0–1.0) of the audio we sent that the far end never received,
  /// as measured by [PeerLossTracker] from the counters on a pong.
  final double lossFraction;

  /// Last measured round trip, or null when nothing has been measured — which
  /// is not the same as fast, and is never graded as such.
  final Duration? rtt;

  /// Nothing measured yet: a fresh session, or a transport with no ping/pong.
  static const unknown = AudioLinkConditions();
}

/// Turns measured link conditions into encoder settings.
///
/// ## Why there is no hysteresis here
///
/// A grader that flaps between tiers is usually a bug, and the usual fix is
/// hysteresis. It is not needed for this one: `OPUS_SET_BITRATE` on a live
/// encoder is a normal, per-frame-cheap operation that libopus is built to
/// absorb — it is how every adaptive VoIP stack works — and the tiers below
/// differ by a few kbps, which is inaudible mid-word. Adding a state machine to
/// damp a change nobody can hear would only make the tuning lag the link.
///
/// Pure — no clock, no I/O, no encoder — so the thresholds can be tested
/// directly, the same way [LinkQualityGrader] is.
class OpusTuner {
  /// Today's ladder — 16 kHz Opus voice. Unchanged by #28.
  const OpusTuner() : _ladder = _Ladder.legacy;

  const OpusTuner._(this._ladder);

  /// HD's ladder — 24 kHz Opus voice, re-derived rather than the legacy
  /// tiers scaled by a multiplier (a multiplier would just be the copy the
  /// roadmap warns against). Bitrates are a deliberate starting point —
  /// roughly the legacy tiers' shape shifted up for the extra bandwidth a
  /// 24 kHz signal needs to sound like an improvement rather than merely
  /// wider silence — not a final, listening-validated ladder; see #28's
  /// physical motorcycle A/B requirement before treating these as settled.
  /// Complexity is one step above the matching legacy tier throughout,
  /// still held well under libopus's max: the CPU floor this app targets
  /// (a Galaxy S8+, sharing the UI isolate with everything else) doesn't
  /// change because the wire got faster.
  static const hd = OpusTuner._(_Ladder.hd);

  /// [profile]'s ladder — [hd] for [AudioFormatProfile.hd24k], the default
  /// (legacy) ladder otherwise. The single place a repository picks between
  /// them, so the branch isn't duplicated at every `_pingPeers`-style tuning
  /// call site.
  factory OpusTuner.forProfile(AudioFormatProfile profile) =>
      profile == AudioFormatProfile.hd24k ? hd : const OpusTuner();

  final _Ladder _ladder;

  /// What a link with no measurements gets.
  ///
  /// Mid-tier bitrate and **no** FEC budget. Zero is right rather than
  /// cautious: an unmeasured link is most often a *reliable* one — Bluetooth
  /// RFCOMM is ordered and lossless, and neither it nor the guest link runs the
  /// unicast ping that produces a measurement — so budgeting redundancy there
  /// would spend bitrate defending against loss that cannot happen.
  static const initial = OpusTuning(
    bitrate: 20000,
    packetLossPerc: 0,
    complexity: 5,
  );

  /// Beyond this, budgeting more redundancy stops helping: libopus spends so
  /// much of the frame on the FEC copy that the primary encoding audibly
  /// suffers, and a link losing a quarter of its datagrams is a job for the
  /// recovery ladder rather than the codec.
  static const maxLossPerc = 25;

  /// Round trip past which the link is treated as congested regardless of loss.
  ///
  /// Same figure as `LinkQualityGrader._rttTolerance`, and deliberately so: on
  /// a LAN this means the AP is queueing hard, and a queue that deep is about
  /// to *become* loss. Backing the bitrate off before it does is the one thing
  /// the encoder can contribute.
  static const congestedRtt = Duration(milliseconds: 150);

  OpusTuning tune(AudioLinkConditions conditions) {
    final lossPerc = (conditions.lossFraction * 100).ceil().clamp(
      0,
      maxLossPerc,
    );

    // A deep queue counts as the first tier of trouble even with no loss yet.
    final rtt = conditions.rtt;
    final congested = rtt != null && rtt > congestedRtt;

    final (bitrate, complexity) = switch (_ladder) {
      _Ladder.legacy => switch (lossPerc) {
        < 2 when !congested => (24000, 6),
        < 8 => (20000, 5),
        < 15 => (16000, 4),
        _ => (12000, 3),
      },
      _Ladder.hd => switch (lossPerc) {
        < 2 when !congested => (32000, 7),
        < 8 => (28000, 6),
        < 15 => (24000, 5),
        _ => (18000, 4),
      },
    };

    return OpusTuning(
      bitrate: bitrate,
      packetLossPerc: lossPerc,
      complexity: complexity,
    );
  }
}

enum _Ladder { legacy, hd }
