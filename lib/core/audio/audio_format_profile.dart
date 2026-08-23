import 'package:equatable/equatable.dart';

/// Which negotiation/capability space a profile belongs to. [supported] and
/// [mediaSupported] are kept as two separate ranked lists precisely so a
/// media profile can never be picked by voice's negotiation — [kind] is what
/// documents and enforces that split at the type level rather than by
/// convention alone.
enum AudioProfileKind { voice, media }

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
    this.kind = AudioProfileKind.voice,
  });

  /// Stable wire capability id, once shipped — this is what a peer advertises
  /// and what negotiation picks between. Never renumber a shipped profile.
  /// Voice and media share this id space (each id still maps to exactly one
  /// profile) even though they negotiate through separate lists — see [kind].
  final int id;

  final int sampleRateHz;

  /// 1 for mono, 2 for interleaved stereo. Carried as a field rather than
  /// assumed so #29's stereo media profiles are not a shape change to this
  /// class.
  final int channels;

  final int frameDurationMs;

  /// [AudioProfileKind.voice] or [AudioProfileKind.media]. Purely a
  /// classification/diagnostics tag — [supported] and [mediaSupported] are
  /// the two lists actually consulted at negotiation time, and each already
  /// only contains profiles of the matching kind by construction.
  final AudioProfileKind kind;

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

  /// The roadmap's HD target. Live behind negotiation as of #28's checkpoint
  /// 3 — but see [supported] for who can actually reach it.
  static const hd24k = AudioFormatProfile(
    id: 2,
    sampleRateHz: 24000,
    channels: 1,
    frameDurationMs: 20,
    label: '24k-HD',
  );

  /// Settings > Advanced > HD Voice, in memory. Defaults on, matching #28
  /// checkpoint 4's build-wide default from before this toggle existed.
  ///
  /// Mutable and read live by [supported] (and, through it, by every
  /// `AudioCapabilityNegotiator` instance and `localBitmask`) rather than
  /// captured once — flipping this mid-call is exactly the same shape of
  /// event as a peer's own support changing mid-call, which negotiation
  /// already has to tolerate, so there is no separate "next session only"
  /// path to maintain. [AppSettings.hdVoiceEnabled] is the persisted source
  /// of truth; whoever loads settings (`main.dart` at cold start,
  /// `SettingsCubit` on toggle) is responsible for writing it here.
  static bool hdVoiceEnabled = true;

  /// Settings > Advanced > HD Shared Music, in memory — [hdVoiceEnabled]'s
  /// twin for [mediaSupported]. [AppSettings.hdMusicEnabled] is the
  /// persisted source of truth.
  static bool hdMusicEnabled = true;

  /// Every voice profile this build can negotiate to, highest-preference-first.
  ///
  /// The single source of truth [AudioCapabilityNegotiator] keys off for
  /// voice. Media profiles ([media48kStereo]/[media48kMono]) are
  /// deliberately **not** in this list — see [mediaSupported] — so media
  /// capability can never be picked for the voice channel.
  ///
  /// [hd24k] was gated to debug builds ([kDebugMode]) through #28's first
  /// three checkpoints, pending the owner/field validation a coding session
  /// can't produce on its own. Checkpoint 4 (2026-08-21) widened it to every
  /// build: two real Android devices ran a live channel end to end,
  /// negotiated `16k -> 24k-HD` within seconds, and held it with zero
  /// jitter-buffer resyncs/drops and zero recovery-ladder events across
  /// 12-14 minute sessions including 500s+ screen-off stretches — see the
  /// decoded `.tarklog` reports attached to #28. Negotiation still falls
  /// back to [legacy16k] automatically for any peer that doesn't advertise
  /// [hd24k] support, so this is additive, not a break for older builds.
  ///
  /// Gated on [hdVoiceEnabled] on top of that: a user who turns HD Voice off
  /// gets a list of one, so neither this build's own negotiator (which never
  /// picks a profile outside this list) nor its advertised [localBitmask]
  /// (which only sets bits for profiles in this list — see
  /// `AudioCapabilityNegotiator.localBitmask`) can end up offering hd24k.
  static List<AudioFormatProfile> get supported =>
      hdVoiceEnabled ? const [hd24k, legacy16k] : const [legacy16k];

  /// #29's HD Shared Music target: 48 kHz, genuinely stereo when the capture
  /// path provides real stereo. Never used to manufacture stereo from a mono
  /// source — see [media48kMono] and `MusicMixer`'s capture-fidelity docs.
  static const media48kStereo = AudioFormatProfile(
    id: 3,
    sampleRateHz: 48000,
    channels: 2,
    frameDurationMs: 20,
    label: '48k-HD-stereo',
    kind: AudioProfileKind.media,
  );

  /// Same wire rate as [media48kStereo], truthful mono for a capture path
  /// that genuinely only provides one channel.
  static const media48kMono = AudioFormatProfile(
    id: 4,
    sampleRateHz: 48000,
    channels: 1,
    frameDurationMs: 20,
    label: '48k-HD-mono',
    kind: AudioProfileKind.media,
  );

  /// Every media profile this build can negotiate to, highest-preference-
  /// first. Kept separate from [supported] on purpose — see that field's
  /// doc. Gated on [hdMusicEnabled] the same way [supported] is gated on
  /// [hdVoiceEnabled]: off yields an empty list, so a media negotiator never
  /// picks (or advertises) either media profile.
  static List<AudioFormatProfile> get mediaSupported =>
      hdMusicEnabled ? const [media48kStereo, media48kMono] : const [];

  @override
  List<Object?> get props => [
    id,
    sampleRateHz,
    channels,
    frameDurationMs,
    kind,
  ];

  @override
  String toString() =>
      'AudioFormatProfile($label, ${sampleRateHz}Hz, ${channels}ch, '
      '${frameDurationMs}ms/$frameSamples samples, ${kind.name})';
}
