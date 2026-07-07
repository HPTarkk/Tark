import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/config/quick_access_config.dart';
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
/// setter reads/writes SharedPreferences directly under the identical keys
/// WalkieTalkieCubit itself uses — the same small duplication already
/// present between LandingCubit and WalkieTalkieCubit for `user_name`.
class SettingsCubit extends Cubit<SettingsState> {
  final WalkieTalkieCubit? _liveSession;
  StreamSubscription<WalkieTalkieState>? _liveSub;

  SettingsCubit({WalkieTalkieCubit? liveSession})
      : _liveSession = liveSession,
        super(SettingsState.initial(isLive: liveSession != null)) {
    _init();
  }

  Future<void> _init() async {
    final live = _liveSession;
    if (live != null) {
      emit(state.copyWith(
        myName: live.state.myName,
        voxThreshold: live.state.voxThreshold,
        noiseSuppression: live.state.noiseSuppression,
      ));
      _liveSub = live.stream.listen((s) {
        if (isClosed) return;
        emit(state.copyWith(
          myName: s.myName,
          voxThreshold: s.voxThreshold,
          noiseSuppression: s.noiseSuppression,
        ));
      });
    } else {
      final prefs = await SharedPreferences.getInstance();
      if (isClosed) return;
      emit(state.copyWith(
        myName: prefs.getString('user_name') ?? '',
        voxThreshold: prefs.getDouble('vox_threshold') ?? state.voxThreshold,
        noiseSuppression:
            prefs.getDouble('noise_suppression') ?? state.noiseSuppression,
      ));
    }
    final prefs = await SharedPreferences.getInstance();
    if (isClosed) return;
    emit(state.copyWith(
      quickAccessEnabled: prefs.getBool(QuickAccessPrefs.enabled) ?? true,
    ));
  }

  Future<void> setMyName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final live = _liveSession;
    if (live != null) {
      await live.setMyName(trimmed);
    } else {
      emit(state.copyWith(myName: trimmed));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_name', trimmed);
    }
  }

  Future<void> setVoxThreshold(double value) async {
    final live = _liveSession;
    if (live != null) {
      await live.setVoxThreshold(value);
    } else {
      emit(state.copyWith(voxThreshold: value));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('vox_threshold', value);
    }
  }

  Future<void> setNoiseSuppression(double value) async {
    final live = _liveSession;
    if (live != null) {
      await live.setNoiseSuppression(value);
    } else {
      emit(state.copyWith(noiseSuppression: value));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('noise_suppression', value);
    }
  }

  Future<void> setQuickAccessEnabled(bool enabled) async {
    emit(state.copyWith(quickAccessEnabled: enabled));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(QuickAccessPrefs.enabled, enabled);
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
  final bool quickAccessEnabled;

  const SettingsState({
    required this.isLive,
    required this.myName,
    required this.voxThreshold,
    required this.noiseSuppression,
    required this.quickAccessEnabled,
  });

  factory SettingsState.initial({required bool isLive}) => SettingsState(
        isLive: isLive,
        myName: '',
        voxThreshold: 0.025,
        noiseSuppression: 0.6,
        quickAccessEnabled: true,
      );

  SettingsState copyWith({
    String? myName,
    double? voxThreshold,
    double? noiseSuppression,
    bool? quickAccessEnabled,
  }) =>
      SettingsState(
        isLive: isLive,
        myName: myName ?? this.myName,
        voxThreshold: voxThreshold ?? this.voxThreshold,
        noiseSuppression: noiseSuppression ?? this.noiseSuppression,
        quickAccessEnabled: quickAccessEnabled ?? this.quickAccessEnabled,
      );

  @override
  List<Object?> get props =>
      [isLive, myName, voxThreshold, noiseSuppression, quickAccessEnabled];
}
