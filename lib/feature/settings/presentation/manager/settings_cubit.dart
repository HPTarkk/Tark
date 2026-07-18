import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/settings/settings_repository_impl.dart';
import '../../../walkie/api/walkie_api.dart';

/// Settings/Profile page state + persistence.
///
/// When opened from an active walkie session (WalkieHeader's gear icon
/// threads the running cubit through go_router's `extra`), [liveSession]
/// makes every mutation delegate straight to the already-running
/// [WalkieTalkieCubit] — so VOX threshold, noise suppression, and name
/// changes apply instantly to the live session instead of only taking effect
/// next time a channel starts. WalkieTalkieCubit is a per-session
/// `@injectable` factory (not a GetIt singleton), so this is the only way to
/// reach the live instance; this cubit never closes it — that's
/// WalkieTalkiePage's own BlocProvider's job.
///
/// Opened from Landing (no session yet), [liveSession] is null and every
/// setter reads/writes through [SettingsRepository] instead — the same
/// repository WalkieTalkieCubit, GuestSessionCubit, LandingCubit, and
/// BluetoothConnectCubit all persist through, so there's one source of
/// truth for these values regardless of which cubit is live.
class SettingsCubit extends Cubit<SettingsState> {
  final WalkieTalkieCubit? _liveSession;
  final SettingsRepository _repository;
  StreamSubscription<WalkieTalkieState>? _liveSub;

  SettingsCubit({
    WalkieTalkieCubit? liveSession,
    SettingsRepository? repository,
  }) : _liveSession = liveSession,
       _repository = repository ?? SettingsRepositoryImpl(),
       super(SettingsState.initial(isLive: liveSession != null)) {
    _init();
  }

  Future<void> _init() async {
    final live = _liveSession;
    if (live != null) {
      // Live values are available synchronously — surface them before the
      // prefs read so the page never shows defaults for the session fields.
      emit(
        state.copyWith(
          myName: live.state.myName,
          voxThreshold: live.state.voxThreshold,
          noiseSuppression: live.state.noiseSuppression,
          noiseSuppressionEngine: live.state.noiseSuppressionEngine,
        ),
      );
      _liveSub = live.stream.listen((s) {
        if (isClosed) return;
        emit(
          state.copyWith(
            myName: s.myName,
            voxThreshold: s.voxThreshold,
            noiseSuppression: s.noiseSuppression,
            noiseSuppressionEngine: s.noiseSuppressionEngine,
          ),
        );
      });
    }

    // One batched prefs read and one emit (instead of a getter+emit per
    // field) — this runs while the page-open transition is animating, so
    // fewer emits means fewer whole-page rebuild passes mid-transition.
    final all = await _repository.loadAll();
    if (isClosed) return;
    emit(
      live != null
          ? state.copyWith(
              quickAccessEnabled: all.quickAccessEnabled,
              targetBufferMs: all.targetBufferMs,
              autoReconnectEnabled: all.autoReconnectEnabled,
              skipSplash: all.skipSplash,
            )
          : state.copyWith(
              myName: all.myName,
              voxThreshold: all.voxThreshold,
              noiseSuppression: all.noiseSuppression,
              noiseSuppressionEngine: all.noiseSuppressionEngine,
              quickAccessEnabled: all.quickAccessEnabled,
              targetBufferMs: all.targetBufferMs,
              autoReconnectEnabled: all.autoReconnectEnabled,
              skipSplash: all.skipSplash,
            ),
    );
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final live = _liveSession;
    if (live != null) {
      await live.setMyName(trimmed);
    } else {
      emit(state.copyWith(myName: trimmed));
      await _repository.setMyName(trimmed);
    }
  }

  Future<void> setVoxThreshold(double value) async {
    final live = _liveSession;
    if (live != null) {
      await live.setVoxThreshold(value);
    } else {
      emit(state.copyWith(voxThreshold: value));
      await _repository.setVoxThreshold(value);
    }
  }

  Future<void> setNoiseSuppression(double value) async {
    final live = _liveSession;
    if (live != null) {
      await live.setNoiseSuppression(value);
    } else {
      emit(state.copyWith(noiseSuppression: value));
      await _repository.setNoiseSuppression(value);
    }
  }

  Future<void> setNoiseSuppressionEngine(NoiseSuppressionEngine engine) async {
    final live = _liveSession;
    if (live != null) {
      await live.setNoiseSuppressionEngine(engine);
    } else {
      emit(state.copyWith(noiseSuppressionEngine: engine));
      await _repository.setNoiseSuppressionEngine(engine);
    }
  }

  /// Resets every Voice-section field to defaults — VOX threshold, noise
  /// suppression and jitter-buffer delay (the recommended hands-free combo:
  /// VOX wide open, noise suppression at full strength to compensate).
  Future<void> restoreVoiceDefaults() async {
    final (vox, noise, buffer) = await _repository.restoreVoiceDefaults();
    final live = _liveSession;
    if (live != null) {
      await live.setVoxThreshold(vox);
      await live.setNoiseSuppression(noise);
      // targetBufferMs isn't pushed to the live session (the jitter buffer
      // doesn't rebuild mid-call) — just reflect the restored value in the
      // page's own state; it's already persisted for the next session.
      emit(state.copyWith(targetBufferMs: buffer));
    } else {
      emit(
        state.copyWith(
          voxThreshold: vox,
          noiseSuppression: noise,
          targetBufferMs: buffer,
        ),
      );
    }
  }

  Future<void> setQuickAccessEnabled(bool enabled) async {
    emit(state.copyWith(quickAccessEnabled: enabled));
    await _repository.setQuickAccessEnabled(enabled);
  }

  // Applies to the next session/reconnect — the audio engine doesn't
  // rebuild its jitter buffer mid-call, so there's no live-session push
  // here (unlike the setters above).
  Future<void> setTargetBufferMs(int value) async {
    emit(state.copyWith(targetBufferMs: value));
    await _repository.setTargetBufferMs(value);
  }

  Future<void> setAutoReconnectEnabled(bool enabled) async {
    emit(state.copyWith(autoReconnectEnabled: enabled));
    final live = _liveSession;
    if (live != null) {
      await live.setAutoReconnectEnabled(enabled);
    } else {
      await _repository.setAutoReconnectEnabled(enabled);
    }
  }

  Future<void> setSkipSplash(bool enabled) async {
    emit(state.copyWith(skipSplash: enabled));
    await _repository.setSkipSplash(enabled);
  }

  @override
  Future<void> close() {
    // _liveSession is a borrowed reference — WalkieTalkiePage's own
    // BlocProvider owns starting/closing it, never this cubit.
    unawaited(_liveSub?.cancel());
    return super.close();
  }
}

class SettingsState extends Equatable {
  final bool isLive;
  final String myName;
  final double voxThreshold;
  final double noiseSuppression;
  final NoiseSuppressionEngine noiseSuppressionEngine;
  final bool quickAccessEnabled;
  final int targetBufferMs;
  final bool autoReconnectEnabled;
  final bool skipSplash;

  const SettingsState({
    required this.isLive,
    required this.myName,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.noiseSuppressionEngine,
    required this.quickAccessEnabled,
    required this.targetBufferMs,
    required this.autoReconnectEnabled,
    required this.skipSplash,
  });

  factory SettingsState.initial({required bool isLive}) => SettingsState(
    isLive: isLive,
    myName: '',
    voxThreshold: 0.0,
    noiseSuppression: 1.0,
    noiseSuppressionEngine: NoiseSuppressionEngine.spectral,
    quickAccessEnabled: true,
    targetBufferMs: 60,
    autoReconnectEnabled: true,
    skipSplash: false,
  );

  SettingsState copyWith({
    String? myName,
    double? voxThreshold,
    double? noiseSuppression,
    NoiseSuppressionEngine? noiseSuppressionEngine,
    bool? quickAccessEnabled,
    int? targetBufferMs,
    bool? autoReconnectEnabled,
    bool? skipSplash,
  }) => SettingsState(
    isLive: isLive,
    myName: myName ?? this.myName,
    voxThreshold: voxThreshold ?? this.voxThreshold,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    noiseSuppressionEngine:
        noiseSuppressionEngine ?? this.noiseSuppressionEngine,
    quickAccessEnabled: quickAccessEnabled ?? this.quickAccessEnabled,
    targetBufferMs: targetBufferMs ?? this.targetBufferMs,
    autoReconnectEnabled: autoReconnectEnabled ?? this.autoReconnectEnabled,
    skipSplash: skipSplash ?? this.skipSplash,
  );

  @override
  List<Object?> get props => [
    isLive,
    myName,
    voxThreshold,
    noiseSuppression,
    noiseSuppressionEngine,
    quickAccessEnabled,
    targetBufferMs,
    autoReconnectEnabled,
    skipSplash,
  ];
}
