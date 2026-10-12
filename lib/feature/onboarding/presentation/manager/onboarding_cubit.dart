import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/profile/avatar_catalog.dart';
import '../../../../core/profile/profile_defaults.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../transfer/api/transfer_api.dart';

/// Drives the first-run journey: which movement is on stage, the callsign
/// being typed, the avatar picked, and the connection choice — all kept local
/// until [finish]/[launch], so backing out or skipping never leaves
/// half-applied profile or connection settings.
///
/// Language and theme are the exception: the hello movement applies them live
/// (seeing the switch IS the point) through LocaleService/ThemeService, which
/// persist themselves. [OnboardingState.themePref] follows ThemeService so the
/// two can never disagree at [finish].
///
/// Three movements, each one tap:
///   hello (what this is + language and look) → you (callsign and face, on
///   one screen) → your room (create one, scan into one, or later).
@injectable
class OnboardingCubit extends Cubit<OnboardingState> {
  static const stepCount = 3;
  static const helloStep = 0;
  static const identityStep = 1;
  static const roomStep = 2;

  /// The longest callsign — the same limit the Profile page enforces.
  static const nameMaxLength = 20;

  /// A theme change re-keys the app subtree (see MyApp.builder). Should that
  /// ever re-inflate this page — and with it a fresh cubit — the outgoing
  /// instance parks its state here and the replacement picks it up, so a
  /// theme switch on the hello movement never loses the journey. Cleared on
  /// [close], so a later run (a replay from Settings) never resumes a stale
  /// journey.
  static OnboardingState? _resumeAfterThemeRekey;

  final TransferModeStore _modeStore;
  final SettingsRepository _settingsRepository;

  OnboardingCubit(this._modeStore, this._settingsRepository)
    : super(
        _resumeAfterThemeRekey ??
            OnboardingState.initial(_modeStore.pinnedMode),
      ) {
    _resumeAfterThemeRekey = null;
    ThemeService.mode.addListener(_onThemeChanged);
    _init();
  }

  void _onThemeChanged() {
    if (isClosed) return;
    emit(state.copyWith(themePref: ThemeService.currentMode));
    _resumeAfterThemeRekey = state;
  }

  static const _stepNames = ['hello', 'identity', 'room'];

  /// The movements are one route, so ScreenLog never sees them change; each
  /// one is logged here as a tab instead.
  @override
  void onChange(Change<OnboardingState> change) {
    super.onChange(change);
    final step = change.nextState.step;
    if (step != change.currentState.step) ScreenLog.tab(_stepNames[step]);
  }

  Future<void> _init() async {
    // Pre-fill from an existing profile so a replay (or a retry after a
    // killed first run) starts from what's already saved.
    final name = await _settingsRepository.getMyName();
    if (!isClosed && name.isNotEmpty && state.name.isEmpty) {
      emit(state.copyWith(name: name));
    }
    final avatarId = await _settingsRepository.getMyAvatarId();
    // A replay starts from the saved avatar; a first run keeps the default.
    if (!isClosed && avatarId != null) {
      emit(state.copyWith(avatarId: avatarId));
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

  /// Jumps straight to a movement without walking there — for tests and
  /// screenshots; the production flow only ever moves via [next]/[back].
  void jumpTo(int step) =>
      emit(state.copyWith(step: step.clamp(0, stepCount - 1)));

  void setName(String value) => emit(state.copyWith(name: value));

  void selectAvatar(int id) => emit(state.copyWith(avatarId: id));

  /// Empty legacy preferences use Wi-Fi/Hotspot.
  void selectMode(TransferMode? mode) =>
      emit(state.withMode(mode ?? TransferMode.wifi));

  /// Records a theme preference without applying it; [finish] applies it.
  /// The hello movement switches the theme live instead (through
  /// ThemeService, which this cubit follows), so this is for callers that
  /// want the old deferred behaviour.
  void selectTheme(AppThemeMode mode) => emit(state.copyWith(themePref: mode));

  /// Persists everything at once and marks onboarding done — the "later" and
  /// replay paths; the page navigates after this future completes.
  Future<void> finish() async {
    final name = state.name.trim();
    if (name.isNotEmpty) await _settingsRepository.setMyName(name);
    final avatarId = state.avatarId;
    if (avatarId != null) await _settingsRepository.setMyAvatarId(avatarId);
    await _modeStore.setPinnedMode(state.mode ?? TransferMode.wifi);
    if (ThemeService.currentMode != state.themePref) {
      await ThemeService.setMode(state.themePref);
    }
    await _markCompleted();
  }

  /// [finish] plus the quick-access "has joined before" flag — the Create
  /// and Join paths, which walk straight on into a Room (the same flag
  /// Landing's own entry points set).
  Future<void> launch() async {
    await finish();
    await _settingsRepository.setHasLaunchedBefore(true);
  }

  /// Marks onboarding done without touching name/mode — the skip path. A
  /// person who skips still gets a default avatar, like everyone who set up
  /// before avatars existed; see [ProfileDefaults.ensureAvatar].
  Future<void> skip() async {
    await _markCompleted();
    await ProfileDefaults.ensureAvatar(_settingsRepository, setupDone: true);
  }

  /// The one exit from onboarding, whichever route got here.
  Future<void> _markCompleted() =>
      _settingsRepository.setOnboardingCompleted(true);

  @override
  Future<void> close() {
    ThemeService.mode.removeListener(_onThemeChanged);
    _resumeAfterThemeRekey = null;
    return super.close();
  }
}

class OnboardingState extends Equatable {
  final int step;
  final String name;

  /// The avatar picked on the identity movement (see AvatarCatalog). Starts
  /// on the Tarkk mascot, [AvatarCatalog.defaultId], so walking past keeps
  /// the default rather than blocking on a choice.
  final int? avatarId;

  /// The connection choice. Null until the person picks one (or a pinned
  /// preference exists); persisted as Wi-Fi/Hotspot when left alone.
  final TransferMode? mode;

  /// The theme preference, kept in step with ThemeService and applied for
  /// good at [OnboardingCubit.finish].
  final AppThemeMode themePref;

  const OnboardingState({
    required this.step,
    required this.name,
    this.avatarId,
    required this.mode,
    required this.themePref,
  });

  factory OnboardingState.initial(TransferMode? mode) => OnboardingState(
    step: 0,
    name: '',
    avatarId: AvatarCatalog.defaultId,
    mode: mode,
    themePref: ThemeService.currentMode,
  );

  /// The identity movement needs a non-blank callsign and a face; every other
  /// movement is always free to advance.
  bool get canContinue => switch (step) {
    OnboardingCubit.identityStep => name.trim().isNotEmpty && avatarId != null,
    _ => true,
  };

  /// The connection the person will end up with — Wi-Fi/Hotspot unless they
  /// chose otherwise, exactly what [OnboardingCubit.finish] persists.
  TransferMode get effectiveMode => mode ?? TransferMode.wifi;

  OnboardingState copyWith({
    int? step,
    String? name,
    int? avatarId,
    AppThemeMode? themePref,
  }) => OnboardingState(
    step: step ?? this.step,
    name: name ?? this.name,
    avatarId: avatarId ?? this.avatarId,
    mode: mode,
    themePref: themePref ?? this.themePref,
  );

  /// Separate from [copyWith] because null means "not chosen" here, and the
  /// `?? this.mode` idiom cannot say it.
  OnboardingState withMode(TransferMode? value) => OnboardingState(
    step: step,
    name: name,
    avatarId: avatarId,
    mode: value,
    themePref: themePref,
  );

  @override
  List<Object?> get props => [step, name, avatarId, mode, themePref];
}
