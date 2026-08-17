import 'package:equatable/equatable.dart';

import '../diagnostics/log_budget.dart';
import 'audio_profile.dart';
import 'noise_suppression_engine.dart';

/// The user-configurable settings this app persists, as a single typed
/// value object. Excludes transport mode, locale, theme, last-Bluetooth-peer
/// and the background-permission-banner dismissal flag — those each already
/// have their own narrow, purpose-built owner (TransferModeStore,
/// LocaleService, ThemeService, BluetoothConnectCubit, the banner widget)
/// and folding them in here would just create a second source of truth.
class AppSettings extends Equatable {
  final String myName;
  final double voxThreshold;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;
  final double musicGain;
  final int targetBufferMs;

  /// Whether the riding preset overrides the voice knobs above. Deliberately
  /// an override and not a writer — see [AudioProfile.resolve], which is the
  /// only thing allowed to combine this with the stored values.
  final bool ridingPreset;
  final bool autoReconnectEnabled;
  final bool skipSplash;
  final bool usageTipsShown;
  final bool analyticsEnabled;

  /// Ceiling on what the diagnostic log may occupy on disk, in bytes. See
  /// [LogBudget] for the range, and `DiagnosticLog` for what enforces it.
  final int logMaxBytes;

  const AppSettings({
    required this.myName,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.musicGain,
    required this.targetBufferMs,
    required this.ridingPreset,
    required this.autoReconnectEnabled,
    required this.skipSplash,
    required this.usageTipsShown,
    required this.analyticsEnabled,
    required this.logMaxBytes,
  });

  /// Canonical defaults, including the hands-free-friendly voice combo: VOX
  /// wide open (0.0) so the mic never gates, with noise suppression at full
  /// strength (1.0) to compensate by cleaning up background/engine noise on
  /// its own.
  factory AppSettings.defaults() => const AppSettings(
    myName: '',
    voxThreshold: 0.0,
    noiseSuppression: 1.0,
    // RNNoise is the production-grade choice — a recurrent-network denoiser
    // handles non-stationary noise (wind, traffic) that spectral subtraction
    // structurally can't, and it's what modern VoIP stacks (WebRTC, Discord)
    // use over classic spectral subtraction. Falls back to spectral
    // automatically wherever the native library isn't compiled in yet (see
    // RnnoiseSuppressor.isAvailable / AudioEngineImpl).
    noiseSuppressionEngine: NoiseSuppressionEngine.rnnoise,
    musicGain: 0.85,
    // Playback jitter-buffer depth. 60 ms was the old value and was
    // measurably too shallow: it drained dry on every scheduling burst even
    // over WiFi, and far worse over Bluetooth, where each underrun costs a
    // full refill pause (heard as chopped speech).
    targetBufferMs: 100,
    // Off by default. The preset is tuned for one situation — a phone in a
    // pocket, a helmet headset, road noise — and it is the wrong setup at a
    // desk, where gating the mic at all only costs word onsets. Making it a
    // deliberate choice also means the sliders on the Advanced page keep
    // meaning what they say for everyone who never touches it.
    ridingPreset: false,
    autoReconnectEnabled: true,
    skipSplash: false,
    usageTipsShown: false,
    // Opt-out rather than opt-in: an opt-in analytics toggle is enabled by
    // roughly nobody, which yields data too sparse to act on. The trade is
    // that it has to be honest — a visible switch in Settings > Privacy, no
    // personal data collected (see lib/core/analytics/analytics_event.dart:
    // every attribute is a bucketed enum, never a name or an address), and
    // it's disclosed in the README and on the website.
    analyticsEnabled: true,
    // The log is a ring, so this is a ceiling and not a target: it costs
    // nothing until a phone actually produces that much, and it buys a bug
    // reported the next morning still being on record. See LogBudget.
    logMaxBytes: LogBudget.defaultBytes,
  );

  AppSettings copyWith({
    String? myName,
    double? voxThreshold,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
    double? musicGain,
    int? targetBufferMs,
    bool? ridingPreset,
    bool? autoReconnectEnabled,
    bool? skipSplash,
    bool? usageTipsShown,
    bool? analyticsEnabled,
    int? logMaxBytes,
  }) => AppSettings(
    myName: myName ?? this.myName,
    voxThreshold: voxThreshold ?? this.voxThreshold,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine: noiseSuppressionEngine ?? this.noiseSuppressionEngine,
    musicGain: musicGain ?? this.musicGain,
    targetBufferMs: targetBufferMs ?? this.targetBufferMs,
    ridingPreset: ridingPreset ?? this.ridingPreset,
    autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    skipSplash: skipSplash ?? this.skipSplash,
    usageTipsShown: usageTipsShown ?? this.usageTipsShown,
    analyticsEnabled: analyticsEnabled ?? this.analyticsEnabled,
    logMaxBytes: logMaxBytes ?? this.logMaxBytes,
  );

  @override
  List<Object?> get props => [
    myName,
    voxThreshold,
    noiseSuppression,
    noiseSuppressionEngine,
    musicGain,
    targetBufferMs,
    ridingPreset,
    autoReconnectEnabled,
    skipSplash,
    usageTipsShown,
    analyticsEnabled,
    logMaxBytes,
  ];
}
