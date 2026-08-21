import 'package:equatable/equatable.dart';

/// The wire-format contract for one direction of real-time audio: sample
/// rate, channel count, and frame duration.
///
/// This is the single source of truth `#28` (negotiated HD Voice) exists to
/// introduce. Before it, the same numbers were duplicated by hand across
/// `feature/audio` (`kTxSampleRate`/`kFrameSamples`) and `feature/transfer`
/// (`kOpusSampleRate`/`kOpusFrameSamples`) — two constants with a doc comment
/// on one admitting it "must agree with" the other, and a third duplicate
/// (`RnnoiseSuppressor._txRate`) with no reference to either. Nothing enforced
/// that agreement; this type is what does now.
///
/// Lives in `core/`, not `feature/audio` or `feature/transfer`: neither
/// feature imports the other's domain today, and this is exactly the kind of
/// entity both legitimately need — the same pattern `core/settings/` and
/// `core/identity/` already follow for state shared across features.
///
/// Deliberately separate from two other, orthogonal axes that must not be
/// folded in here: `OpusEncodeProfile` (what the signal *is* — speech vs
/// music) and `OpusTuning` (the link-adaptive bitrate/FEC/complexity at a
/// fixed format). This type only answers "what's the rate/frame contract."
class AudioFormatProfile extends Equatable {
  const AudioFormatProfile({
    required this.id,
    required this.sampleRateHz,
    required this.channels,
    required this.frameDurationMs,
    required this.label,
  });

  /// Stable wire capability id, once shipped — this is what a peer advertises
  /// and what negotiation picks between. Never renumber a shipped profile.
  final int id;

  final int sampleRateHz;

  /// 1 today. Carried as a field rather than assumed so a future stereo
  /// profile (e.g. for #29's HD music) isn't a shape change to this class.
  final int channels;

  final int frameDurationMs;

  /// Samples in one wire frame. Opus only accepts exact frame durations
  /// (2.5/5/10/20/40/60 ms), so this is a hard constraint on the capture path
  /// rather than a tuning choice.
  int get frameSamples => sampleRateHz * frameDurationMs ~/ 1000;

  /// For logs and diagnostics.
  final String label;

  /// The production profile shipped before #28, and the permanent fallback: a
  /// peer that never advertises capability is always assumed to be here.
  static const legacy16k = AudioFormatProfile(
    id: 1,
    sampleRateHz: 16000,
    channels: 1,
    frameDurationMs: 20,
    label: '16k',
  );

  /// The roadmap's HD target. Not yet reachable: see [supported].
  static const hd24k = AudioFormatProfile(
    id: 2,
    sampleRateHz: 24000,
    channels: 1,
    frameDurationMs: 20,
    label: '24k-HD',
  );

  /// Every profile this build can negotiate to, highest-preference-first.
  ///
  /// The single source of truth both the capability negotiator and (later)
  /// #29's media-profile registry key off. [legacy16k] only for now —
  /// negotiation cannot yet resolve to [hd24k] regardless of what a peer
  /// advertises. Ids 3+ are reserved for a future media profile so #29 can
  /// extend this without touching voice's numbering.
  static const supported = [legacy16k];

  @override
  List<Object?> get props => [id, sampleRateHz, channels, frameDurationMs];

  @override
  String toString() =>
      'AudioFormatProfile($label, ${sampleRateHz}Hz, ${channels}ch, '
      '${frameDurationMs}ms/$frameSamples samples)';
}
