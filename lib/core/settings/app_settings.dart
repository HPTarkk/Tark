import 'package:equatable/equatable.dart';

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
    required this.musicGain,
    required this.targetBufferMs,
    required this.autoReconnectEnabled,
    required this.skipSplash,
    required this.quickAccessEnabled,
    required this.usageTipsShown,
  });

  /// Canonical defaults, including the hands-free-friendly voice combo: VOX
  /// wide open (0.0) so the mic never gates, with noise suppression raised
  /// to compensate by cleaning up background/engine noise on its own.
  factory AppSettings.defaults() => const AppSettings(
    myName: '',
    voxThreshold: 0.0,
    noiseSuppression: 0.8,
    musicGain: 0.85,
    targetBufferMs: 100,
    autoReconnectEnabled: true,
    skipSplash: false,
    quickAccessEnabled: true,
    usageTipsShown: false,
  );

  AppSettings copyWith({
    String? myName,
    double? voxThreshold,
    double? noiseSuppression,
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
    musicGain,
    targetBufferMs,
    autoReconnectEnabled,
    skipSplash,
    quickAccessEnabled,
    usageTipsShown,
  ];
}
