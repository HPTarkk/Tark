import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/config/onboarding_config.dart';
import '../../../../core/config/quick_access_config.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../transfer/api/transfer_api.dart';

/// Drives the first-run onboarding journey: which beat is on stage, the
/// callsign being typed, and the transport choice — all kept local until
/// [finish]/[launch], so backing out or skipping never leaves half-applied
/// settings. (Language and theme are the exception: the tune-in beat applies
/// them live through LocaleService/ThemeService because seeing the switch IS
/// the point, and both persist themselves.)
@injectable
class OnboardingCubit extends Cubit<OnboardingState> {
  static const stepCount = 5;
  static const tuneStep = 0;
  static const welcomeStep = 1;
  static const callsignStep = 2;
  static const transportStep = 3;
  static const launchStep = 4;

  /// A theme change re-keys the whole app subtree (see MyApp.builder), which
  /// re-inflates this page and rebuilds its cubit mid-journey. The outgoing
  /// instance parks its state here (via the [ThemeService.mode] listener
  /// below) and the replacement picks it up, so toggling the theme on the
  /// tune-in beat never loses the step, name, or transport choice.
  static OnboardingState? _resumeAfterThemeRekey;

  final TransferModeStore _modeStore;
  final SettingsRepository _settingsRepository;

  OnboardingCubit(this._modeStore, this._settingsRepository)
    : super(
        _resumeAfterThemeRekey ?? OnboardingState.initial(_modeStore.mode),
      ) {
    _resumeAfterThemeRekey = null;
    ThemeService.mode.addListener(_onThemeChanged);
    _init();
  }

  void _onThemeChanged() => _resumeAfterThemeRekey = state;

  Future<void> _init() async {
    // Pre-fill from an existing profile so a replay (or a retry after a
    // killed first run) starts from what's already saved.
    final name = await _settingsRepository.getMyName();
    if (!isClosed && name.isNotEmpty && state.name.isEmpty) {
      emit(state.copyWith(name: name));
    }
  }

  void next() {
    if (state.step < stepCount - 1 && state.canContinue) {
      emit(state.copyWith(step: state.step + 1));
    }
  }

  void back() {
    if (state.step > 0) emit(state.copyWith(step: state.step - 1));
  }

  /// Jumps straight to a beat without walking there — used by the preview
  /// harness (see lib/main_onboarding_preview.dart) to deep-link a beat for
  /// screenshots; production flow only ever moves via [next]/[back].
  void jumpTo(int step) =>
      emit(state.copyWith(step: step.clamp(0, stepCount - 1)));

  void setName(String value) => emit(state.copyWith(name: value));

  void selectMode(TransferMode mode) => emit(state.copyWith(mode: mode));

  /// Records the theme preference (previewed live as the sky's time of day);
  /// the real [ThemeService] switch is deferred to [finish] so the flow stays
  /// free of the global re-key.
  void selectTheme(AppThemeMode mode) => emit(state.copyWith(themePref: mode));

  /// Persists everything at once and marks onboarding done — the "explore
  /// the lobby first" and replay paths; the page navigates after this
  /// future completes.
  Future<void> finish() async {
    final name = state.name.trim();
    if (name.isNotEmpty) await _settingsRepository.setMyName(name);
    await _modeStore.setMode(state.mode);
    // Apply the deferred theme choice now, on the way out — the global re-key
    // it triggers is harmless here since we're leaving the flow.
    if (ThemeService.currentMode != state.themePref) {
      await ThemeService.setMode(state.themePref);
    }
    await _markCompleted();
  }

  /// [finish] plus the quick-access "has joined before" flag — the primary
  /// JOIN CHANNEL path, which drops the user straight into their transport's
  /// join flow (the same flag Landing's Join button sets).
  Future<void> launch() async {
    await finish();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(QuickAccessPrefs.hasLaunchedBefore, true);
  }

  /// Marks onboarding done without touching name/mode — the skip path.
  Future<void> skip() => _markCompleted();

  Future<void> _markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(OnboardingPrefs.completed, true);
  }

  @override
  Future<void> close() {
    ThemeService.mode.removeListener(_onThemeChanged);
    return super.close();
  }
}

class OnboardingState extends Equatable {
  final int step;
  final String name;
  final TransferMode mode;

  /// The theme the user has chosen on the tune beat. Held here (not pushed to
  /// [ThemeService]) so the flow never triggers the global theme re-key that
  /// would kill the scene's sunrise/sunset animation — it's applied for real
  /// only at [OnboardingCubit.finish]. The environmental sky IS the live
  /// preview of this choice.
  final AppThemeMode themePref;

  const OnboardingState({
    required this.step,
    required this.name,
    required this.mode,
    required this.themePref,
  });

  factory OnboardingState.initial(TransferMode mode) => OnboardingState(
    step: 0,
    name: '',
    mode: mode,
    themePref: ThemeService.currentMode,
  );

  /// The callsign beat gates its CTA on a non-blank name; every other beat
  /// is always free to advance.
  bool get canContinue =>
      step != OnboardingCubit.callsignStep || name.trim().isNotEmpty;

  OnboardingState copyWith({
    int? step,
    String? name,
    TransferMode? mode,
    AppThemeMode? themePref,
  }) => OnboardingState(
    step: step ?? this.step,
    name: name ?? this.name,
    mode: mode ?? this.mode,
    themePref: themePref ?? this.themePref,
  );

  @override
  List<Object?> get props => [step, name, mode, themePref];
}
