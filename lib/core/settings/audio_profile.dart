import 'package:equatable/equatable.dart';

import 'noise_suppression_engine.dart';
import 'suppression_plan.dart';

/// The audio values that actually reach the engine, after the riding preset
/// has had its say.
///
/// Nothing downstream reads a raw stored knob any more: `AudioEngineImpl`
/// (jitter depth, playback gain) and `WalkieTalkieCubit` (VOX, cleaner) both
/// take their values from here, so there is exactly one place where "preset
/// on" changes what the audio chain does. A caller that read the preference
/// directly would be the whole bug this type exists to prevent — the preset
/// would apply to some of the chain and not the rest, which is worse than not
/// having it.
class AudioProfile extends Equatable {
  final double voxMargin;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;
  final int targetBufferMs;

  /// Linear gain applied to received voice before the jitter buffer. 1.0 is
  /// untouched; see [RidingPreset.playbackGain] for why the preset raises it
  /// and `AudioEngine.setPlaybackGain` for what stops it clipping.
  final double playbackGain;

  /// Whether these values came from the preset rather than the user's own
  /// sliders. Presentation needs this to show the sliders as overridden —
  /// a preset that silently contradicts a control two taps away is worse
  /// than no preset.
  final bool fromPreset;

  const AudioProfile({
    required this.voxMargin,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.targetBufferMs,
    required this.playbackGain,
    required this.fromPreset,
  });

  /// Resolves what the audio chain should run, from what the user stored and
  /// whether the riding preset is on.
  ///
  /// The preset **overrides, it never overwrites**. Every stored value is
  /// passed through untouched when the preset is off, and the preset's own
  /// values are never written back to preferences — so turning it off returns
  /// the rider to exactly the setup they had, which is the only way a toggle
  /// like this is safe to try mid-ride. Same idiom as the noise slider going
  /// inert when the cleaner is off (see AdvancedSettingsPage).
  factory AudioProfile.resolve({
    required bool ridingPreset,
    required double voxMargin,
    required double noiseSuppression,
    required NoiseSuppressionEngine noiseSuppressionEngine,
    required int targetBufferMs,
  }) => ridingPreset
      ? RidingPreset.profile
      : AudioProfile(
          voxMargin: voxMargin,
          noiseSuppression: noiseSuppression,
          noiseSuppressionEngine: noiseSuppressionEngine,
          targetBufferMs: targetBufferMs,
          playbackGain: 1.0,
          fromPreset: false,
        );

  @override
  List<Object?> get props => [
    voxMargin,
    noiseSuppression,
    noiseSuppressionEngine,
    targetBufferMs,
    playbackGain,
    fromPreset,
  ];
}

/// The one-toggle riding profile: what a phone in a jacket pocket, on a bike,
/// behind a helmet headset should be doing.
///
/// ## What it deliberately does *not* claim to switch on
///
/// Most of what a "riding mode" would want is already permanent, and the
/// preset would be lying if it presented any of it as its own doing:
///
/// * echo cancellation, noise suppression and AGC — the platform's own, bound
///   to every capture session by `VoiceAudioSession.attachEffects`
/// * headset priority — `VoiceAudioSession.configure` puts the session in
///   phone-call mode, so mic and playback follow a handsfree device whenever
///   one is attached, and re-follow it mid-session on a route change
/// * jitter depth adaptation and Opus retuning — both run off measured link
///   conditions every session, preset or not
///
/// So the preset moves the four stored knobs and the playback gain, and
/// nothing else. That is a smaller list than it sounds, because of the first
/// entry below.
///
/// ## Why VOX is the one that matters
///
/// The app ships with the VOX margin at 0, and 0 is a hard contract meaning
/// *the gate is off entirely* — `NoiseFloorTracker.thresholdFor` returns 0
/// unchanged and `VoxGate` takes its never-hold-anything-back path. The
/// consequence is easy to miss: on a default install the noise-floor tracking
/// never gates anything at all, because there is no gate for it to move. At a
/// desk that is the right default — everything the mic hears is worth sending.
/// At 100 km/h it means the rider holds the channel open with wind noise for
/// the whole ride and nothing on their own phone tells them so.
///
/// Arming that gate is the preset's real work, and now that the slider is a
/// margin rather than an absolute level, arming it is also the *only* work: the
/// value below is a distance above whatever the mic is hearing, so the preset
/// no longer has to guess how loud a helmet is.
abstract final class RidingPreset {
  /// ≈ 10.5 dB above the measured background.
  ///
  /// The value this replaced was 0.02 on the old absolute scale, chosen to be
  /// deliberately *low* — its whole job was to arm the gate and then get out of
  /// the way of the fixed 2.5× the tracker applied, because a higher absolute
  /// number would have out-shouted the tracker and clipped word onsets indoors.
  /// That trade is gone: a margin cannot out-shout the tracker, it *is* the
  /// tracker's setting, so the preset can finally state a real one.
  ///
  /// 10.5 dB rather than the 8 dB everyone has been running, because the helmet
  /// is the case where wind gusts push the background around between the
  /// tracker's updates, and a rider on a boom mic clears a wide margin easily —
  /// their mouth is centimetres from the capsule while the wind is not.
  ///
  /// Unverified on hardware, like the rest of the preset's numbers.
  static const double voxMargin = 0.5;

  /// Moderate, not maximum. The standing P1 constraint is *intelligibility*,
  /// not silence: aggressive suppression eats the consonants that carry a word
  /// through a helmet, and it does it worst on exactly the non-stationary wind
  /// noise a rider has most of. Full strength is still one slider away for
  /// anyone who wants it.
  ///
  /// The stock default now reads the same ceiling, so what this does here is
  /// **pin** the value rather than lower it: a rider who dragged the slider to
  /// 100 % gets pulled back for the ride, and finds their own value again
  /// untouched the moment they turn the preset off.
  static const double noiseSuppression = SuppressionPlan.ceiling;

  /// RNNoise alone, never [NoiseSuppressionEngine.both]. Cascading spectral
  /// subtraction on top of a recurrent denoiser is the over-suppression trap
  /// in its purest form — two cleaners each removing what the other left.
  static const NoiseSuppressionEngine engine = NoiseSuppressionEngine.rnnoise;

  /// Anchors the adaptive jitter buffer higher: the ×0.6–×1.8 band around this
  /// becomes ~84–252 ms instead of the default's 60–180 ms, so a link between
  /// two moving bikes has somewhere to grow to. Not fixed *at* the top of that
  /// band — the buffer still gives the latency back on a link that turns out
  /// to be clean.
  static const int targetBufferMs = 140;

  /// A modest lift, because the competition is a helmet at road speed rather
  /// than a quiet room. Kept small and soft-limited (see
  /// `AudioEngine.setPlaybackGain`): loud-and-distorted is less intelligible
  /// than quiet-and-clean, which would defeat the point.
  static const double playbackGain = 1.3;

  static const AudioProfile profile = AudioProfile(
    voxMargin: voxMargin,
    noiseSuppression: noiseSuppression,
    noiseSuppressionEngine: engine,
    targetBufferMs: targetBufferMs,
    playbackGain: playbackGain,
    fromPreset: true,
  );
}
