import 'package:equatable/equatable.dart';

import 'noise_suppression_engine.dart';

/// Which cleaners actually run on the TX path and how hard each is allowed to
/// work — resolved in one place from the engine choice, the user's single
/// strength slider, and whether the native denoiser loaded.
///
/// ## The constraint this exists to enforce
///
/// The target is *maximum intelligibility*, not studio quiet. Every suppressor
/// here buys silence by removing signal, and the first signal it removes is the
/// part of speech that most resembles noise: the fricatives and stops — /s/,
/// /f/, /th/, /t/, /k/ — that carry the difference between "fifty" and "sixty"
/// through a helmet. A lossy link is chewing the same consonants from the other
/// end, so the two compound rather than trade off. Quieter and less
/// understandable is a loss, not a win.
///
/// ## The two places that constraint was quietly being broken
///
/// **The shipped default was maximum.** `AppSettings.defaults()` sent 1.0 to
/// the cleaner — *more* aggressive than the riding preset, the profile tuned
/// for a helmet at road speed, which documents backing away from full strength
/// for exactly this reason. A stock install therefore ran the setting the
/// worst-case profile exists to avoid, in the best-case environment: at a desk
/// there is the least noise to remove and so the worst ratio of speech damaged
/// to noise gained. [ceiling] is now the most any shipped configuration asks
/// for, and both of them read it from here.
///
/// **The cascade doubled up.** [NoiseSuppressionEngine.both] is described as
/// RNNoise first, then spectral subtraction "to mop up any residual steady
/// hum". It was implemented as two cleaners at the same full slider value: the
/// residuals multiply, and worse, the second stage subtracts against a signal
/// whose remaining noise is no longer the stationary kind its floor tracker
/// assumes — so it over-subtracts, and it does it into speech. The second stage
/// now gets [mopUpShare] of the slider, which is what "mop up" was supposed to
/// mean all along.
///
/// Pure, so the whole matrix — every engine × available/not — is testable
/// without an audio device.
class SuppressionPlan extends Equatable {
  /// The most cleaning any *shipped* configuration asks for.
  ///
  /// Shared deliberately by the stock default and the riding preset rather than
  /// written out twice: the preset's job at this knob is to *pin* the value
  /// against a slider someone cranked to 100 %, not to raise it. Anyone who
  /// wants more is still one slider away — this bounds what we choose for
  /// people, not what they may choose for themselves.
  static const double ceiling = 0.65;

  /// What the *second* stage of a running cascade gets, as a share of the
  /// slider. Half: enough to take a residual hum off RNNoise's output, not
  /// enough to be a second full cleaner.
  static const double mopUpShare = 0.5;

  /// Whether the recurrent denoiser runs, and at what strength (a dry/wet mix —
  /// see `RnnoiseSuppressor`).
  final bool useRnnoise;
  final double rnnoiseStrength;

  /// Whether spectral subtraction runs, and at what strength (an aggression
  /// curve: over-subtraction factor and attenuation floor — see
  /// `SpectralNoiseSuppressor`).
  ///
  /// The two strengths are not the same quantity, which is the other reason
  /// this type exists: one slider drives two engines whose 0..1 means different
  /// things, and only a resolver that knows both can keep them comparable.
  final bool useSpectral;
  final double spectralStrength;

  const SuppressionPlan({
    required this.useRnnoise,
    required this.rnnoiseStrength,
    required this.useSpectral,
    required this.spectralStrength,
  });

  factory SuppressionPlan.resolve({
    required NoiseSuppressionEngine engine,
    required double strength,
    required bool rnnoiseAvailable,
  }) {
    final s = strength.clamp(0.0, 1.0);

    // Spelled out per-engine rather than as "!= x" conditions — the negative
    // form silently enrolled any newly added enum value into both suppressors,
    // which is exactly the bug `off` would have hit.
    final wantsRnnoise =
        engine == NoiseSuppressionEngine.rnnoise ||
        engine == NoiseSuppressionEngine.both;
    final useRnnoise = wantsRnnoise && rnnoiseAvailable;

    // `rnnoise` and `both` degrade to spectral alone wherever the native
    // library isn't compiled in. `off` is the one choice that degrades to
    // nothing instead: a user who asked for no cleaning has not asked for a
    // different cleaner.
    final useSpectral =
        engine == NoiseSuppressionEngine.spectral ||
        engine == NoiseSuppressionEngine.both ||
        (wantsRnnoise && !useRnnoise);

    // The reduction keys on a cascade that is actually *running*, not on the
    // choice of `both`. With the native library missing, `both` collapses to
    // spectral alone, and a lone cleaner silently running at half strength
    // would be a second downgrade on precisely the devices that already lost
    // the better engine.
    final cascaded = useRnnoise && useSpectral;

    return SuppressionPlan(
      useRnnoise: useRnnoise,
      rnnoiseStrength: useRnnoise ? s : 0.0,
      useSpectral: useSpectral,
      spectralStrength: useSpectral ? (cascaded ? s * mopUpShare : s) : 0.0,
    );
  }

  @override
  List<Object?> get props => [
    useRnnoise,
    rnnoiseStrength,
    useSpectral,
    spectralStrength,
  ];
}
