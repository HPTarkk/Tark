import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/profile/avatar_catalog.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/core/theme/theme_service.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

class _Settings implements SettingsRepository {
  String name = '';
  int? avatarId;
  bool completed = false;
  bool launched = false;

  @override
  Future<String> getMyName() async => name;

  @override
  Future<void> setMyName(String value) async => name = value;

  @override
  Future<int?> getMyAvatarId() async => avatarId;

  @override
  Future<void> setMyAvatarId(int value) async => avatarId = value;

  @override
  Future<void> setOnboardingCompleted(bool value) async => completed = value;

  @override
  Future<void> setHasLaunchedBefore(bool value) async => launched = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Modes implements TransferModeStore {
  _Modes([this.pinned]);

  TransferMode? pinned;

  @override
  TransferMode? get pinnedMode => pinned;

  @override
  Future<void> setPinnedMode(TransferMode? mode) async => pinned = mode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Settings settings;
  late _Modes modes;
  late OnboardingCubit cubit;

  setUp(() async {
    SharedPreferences.setMockInitialValues({SettingsKeys.appTheme: 'dark'});
    ThemeService.initialize(await SharedPreferences.getInstance());
    settings = _Settings();
    modes = _Modes();
    cubit = OnboardingCubit(modes, settings);
  });

  tearDown(() => cubit.close());

  test('three movements, the room last', () {
    expect(OnboardingCubit.stepCount, 3);
    expect(OnboardingCubit.identityStep, OnboardingCubit.helloStep + 1);
    expect(OnboardingCubit.roomStep, OnboardingCubit.stepCount - 1);
  });

  test('the identity movement needs a callsign, and starts on the mascot', () {
    cubit.next();
    expect(cubit.state.step, OnboardingCubit.identityStep);
    expect(cubit.state.avatarId, AvatarCatalog.defaultId);
    expect(cubit.state.canContinue, isFalse);
    cubit
      ..setName('   ')
      ..next();
    expect(cubit.state.step, OnboardingCubit.identityStep);
    cubit
      ..setName('Pedi')
      ..selectAvatar(4)
      ..next();
    expect(cubit.state.step, OnboardingCubit.roomStep);
    expect(cubit.state.avatarId, 4);
    // Nothing moves past the last movement.
    cubit.next();
    expect(cubit.state.step, OnboardingCubit.roomStep);
  });

  test('walking past the faces keeps the default', () async {
    cubit.setName('Pedi');
    await cubit.finish();
    expect(settings.avatarId, AvatarCatalog.defaultId);
  });

  test(
    'finishing saves everything, launching also marks a first launch',
    () async {
      cubit
        ..setName('  Pedi  ')
        ..selectAvatar(6);
      await cubit.finish();
      expect(settings.name, 'Pedi');
      expect(settings.avatarId, 6);
      expect(settings.completed, isTrue);
      expect(settings.launched, isFalse);
      // An untouched connection is persisted as Wi-Fi/Hotspot.
      expect(modes.pinned, TransferMode.wifi);
      expect(cubit.state.effectiveMode, TransferMode.wifi);

      cubit.selectMode(TransferMode.bluetooth);
      await cubit.launch();
      expect(settings.launched, isTrue);
      expect(modes.pinned, TransferMode.bluetooth);
    },
  );

  test(
    'skipping still leaves a default avatar and touches nothing else',
    () async {
      cubit
        ..setName('Draft')
        ..selectMode(TransferMode.guest);
      await cubit.skip();
      expect(settings.avatarId, AvatarCatalog.defaultId);
      expect(settings.name, '');
      expect(modes.pinned, isNull);
      expect(settings.completed, isTrue);
    },
  );

  test('a replay starts from the saved profile and connection', () async {
    settings
      ..avatarId = 9
      ..name = 'Saved';
    final replay = OnboardingCubit(_Modes(TransferMode.guest), settings);
    addTearDown(replay.close);
    await pumpEventQueue();
    expect(replay.state.avatarId, 9);
    expect(replay.state.name, 'Saved');
    expect(replay.state.effectiveMode, TransferMode.guest);
  });

  test('the theme preference follows the live theme switch', () async {
    expect(cubit.state.themePref, AppThemeMode.dark);
    await ThemeService.setMode(AppThemeMode.light);
    expect(cubit.state.themePref, AppThemeMode.light);
    // Finishing keeps what is on screen instead of reverting it.
    await cubit.finish();
    expect(ThemeService.currentMode, AppThemeMode.light);
    await ThemeService.setMode(AppThemeMode.dark);
  });

  test('a later run never resumes a closed journey', () async {
    cubit
      ..setName('Old run')
      ..jumpTo(OnboardingCubit.roomStep);
    await ThemeService.setMode(AppThemeMode.light);
    await cubit.close();
    final next = OnboardingCubit(modes, settings);
    addTearDown(next.close);
    expect(next.state.step, OnboardingCubit.helloStep);
    expect(next.state.name, isEmpty);
    await ThemeService.setMode(AppThemeMode.dark);
  });
}
