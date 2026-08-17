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
  const OpusTuner();

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

    final (bitrate, complexity) = switch (lossPerc) {
      < 2 when !congested => (24000, 6),
      < 8 => (20000, 5),
      < 15 => (16000, 4),
      _ => (12000, 3),
    };

    return OpusTuning(
      bitrate: bitrate,
      packetLossPerc: lossPerc,
      complexity: complexity,
    );
  }
}
