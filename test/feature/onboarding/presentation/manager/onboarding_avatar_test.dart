import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/profile/avatar_catalog.dart';
import 'package:tark/core/settings/settings_repository.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

class _Settings implements SettingsRepository {
  String name = '';
  int? avatarId;
  bool completed = false;

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
  Future<void> setHasLaunchedBefore(bool value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Modes implements TransferModeStore {
  @override
  TransferMode? get pinnedMode => null;

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Settings settings;
  late OnboardingCubit cubit;

  setUp(() {
    settings = _Settings();
    cubit = OnboardingCubit(_Modes(), settings);
  });

  tearDown(() => cubit.close());

  test('the avatar beat comes right after the callsign', () {
    expect(OnboardingCubit.avatarStep, OnboardingCubit.callsignStep + 1);
    expect(OnboardingCubit.launchStep, OnboardingCubit.stepCount - 1);
  });

  test('the avatar beat waits for a pick', () {
    cubit
      ..setName('Pedi')
      ..jumpTo(OnboardingCubit.avatarStep);
    expect(cubit.state.canContinue, isFalse);
    cubit.next();
    expect(cubit.state.step, OnboardingCubit.avatarStep);

    cubit.selectAvatar(4);
    expect(cubit.state.canContinue, isTrue);
    cubit.next();
    expect(cubit.state.step, OnboardingCubit.transportStep);
  });

  test('finishing saves the picked avatar', () async {
    cubit
      ..setName('Pedi')
      ..selectAvatar(6);
    await cubit.finish();
    expect(settings.avatarId, 6);
    expect(settings.completed, isTrue);
  });

  test('skipping still leaves a default avatar', () async {
    await cubit.skip();
    expect(settings.avatarId, AvatarCatalog.defaultFor(''));
  });

  test('a replay starts from the saved avatar', () async {
    settings.avatarId = 9;
    final replay = OnboardingCubit(_Modes(), settings);
    addTearDown(replay.close);
    await pumpEventQueue();
    expect(replay.state.avatarId, 9);
  });
}
