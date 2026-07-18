import 'package:equatable/equatable.dart';

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
  final bool autoReconnectEnabled;
  final bool skipSplash;
  final bool quickAccessEnabled;
  final bool usageTipsShown;

  const AppSettings({
    required this.myName,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.musicGain,
    required this.targetBufferMs,
    required this.autoReconnectEnabled,
    required this.skipSplash,
    required this.quickAccessEnabled,
    required this.usageTipsShown,
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
    targetBufferMs: 60,
    autoReconnectEnabled: true,
    skipSplash: false,
    quickAccessEnabled: true,
    usageTipsShown: false,
  );

  AppSettings copyWith({
    String? myName,
    double? voxThreshold,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
    double? musicGain,
    int? targetBufferMs,
    bool? autoReconnectEnabled,
    bool? skipSplash,
    bool? quickAccessEnabled,
    bool? usageTipsShown,
  }) => AppSettings(
    myName: myName ?? this.myName,
    voxThreshold: voxThreshold ?? this.voxThreshold,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine: noiseSuppressionEngine ?? this.noiseSuppressionEngine,
    musicGain: musicGain ?? this.musicGain,
    targetBufferMs: targetBufferMs ?? this.targetBufferMs,
    autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    skipSplash: skipSplash ?? this.skipSplash,
    quickAccessEnabled: quickAccessEnabled ?? this.quickAccessEnabled,
    usageTipsShown: usageTipsShown ?? this.usageTipsShown,
  );

  @override
  List<Object?> get props => [
    myName,
    voxThreshold,
    noiseSuppression,
    noiseSuppressionEngine,
    musicGain,
    targetBufferMs,
    autoReconnectEnabled,
    skipSplash,
    quickAccessEnabled,
    usageTipsShown,
  ];
}
