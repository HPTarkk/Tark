import 'package:equatable/equatable.dart';

/// The libopus encoder settings this app varies while a call is running.
///
/// Deliberately only the knobs that can be changed on a *live* encoder through
/// `opus_encoder_ctl`. The application mode (voip vs audio) is not here: it is
/// fixed at encoder-construction time and changing it means rebuilding the
/// encoder, which is why it stays on `OpusEncodeProfile` where the rebuild is
/// visible at the call site.
///
/// ## What is not tuned, and why
///
/// **Sample rate.** The roadmap asks for 24/48 kHz on a good link. That is not
/// a codec setting here: it is `AudioFormatProfile` (`core/audio/`) — the mic
/// resampler targets its rate, `AudioProcessor` is built at it, and a frame is
/// sized by it — so raising it is a pipeline change on both ends plus a
/// wire-format negotiation, not a CTL. See `AudioFormatProfile.supported`.
///
/// **Audio bandwidth.** Left at libopus's own choice (`OPUS_AUTO`). Forcing
/// narrowband on a weak link is the obvious lever and the wrong one: it strips
/// the high end where consonants live, which is the exact failure the roadmap
/// warns about under "do not over-suppress". Loss is answered with redundancy
/// ([packetLossPerc]) rather than by throwing away the top of the voice, and
/// libopus narrows the band on its own if [bitrate] genuinely cannot carry it.
class OpusTuning extends Equatable {
  const OpusTuning({
    required this.bitrate,
    required this.packetLossPerc,
    required this.complexity,
  });

  /// Target bitrate in bits per second, for the 16 kHz mono voice stream.
  final int bitrate;

  /// Loss percentage the encoder budgets in-band FEC for (0–100).
  ///
  /// This is the whole FEC control surface. In-band FEC is left *enabled* for
  /// the life of the encoder and costs nothing at zero, because libopus only
  /// spends bits on the redundant copy in proportion to this number. So there
  /// is no "turn FEC on" moment to get wrong — a clean link simply budgets 0 %
  /// and encodes exactly as it did before.
  final int packetLossPerc;

  /// libopus complexity, 0–10. Lower is cheaper on the CPU and slightly worse
  /// at the same bitrate. Kept modest throughout: the floor this app targets is
  /// a Galaxy S8+, where the whole audio path shares the UI isolate.
  final int complexity;

  @override
  List<Object?> get props => [bitrate, packetLossPerc, complexity];

  @override
  String toString() =>
      'OpusTuning(${bitrate ~/ 1000}kbps, loss=$packetLossPerc%, '
      'complexity=$complexity)';
}
