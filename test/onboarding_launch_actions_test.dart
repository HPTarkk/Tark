import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/onboarding/presentation/manager/onboarding_cubit.dart';
import 'package:tark/feature/onboarding/presentation/widget/onboarding_launch_actions.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

/// The last beat used to end on two calls to action that, for almost every
/// first run, did exactly the same thing: with no transport pinned the primary
/// key had no flow to walk and landed on the room screen, which is precisely
/// where the quiet "look around first" link went. One breathed and one
/// whispered, and they were the same button.
void main() {
  group('the primary key only promises a channel when there is one', () {
    test('a pinned transport really does walk into a setup flow', () {
      for (final mode in TransferMode.values) {
        expect(
          OnboardingLaunchActions.joinsAChannel(replay: false, mode: mode),
          isTrue,
          reason: '$mode was pinned, so the key walks its flow',
        );
      }
    });

    test('automatic does not — it finishes setup and lands on the room screen', () {
      // The transport beat pre-selects AUTOMATIC, so this is the state almost
      // every first run ends in. The advisor needs an intent to resolve a
      // transport, and the only thing that supplies one is the user tapping
      // START or JOIN on the room screen.
      expect(
        OnboardingLaunchActions.joinsAChannel(replay: false, mode: null),
        isFalse,
      );
    });

    test('a replay from Settings never claims to join anything', () {
      // It pops back to Settings; there is no channel at the end of it.
      for (final mode in [null, ...TransferMode.values]) {
        expect(
          OnboardingLaunchActions.joinsAChannel(replay: true, mode: mode),
          isFalse,
          reason: 'replay with mode $mode',
        );
      }
    });
  });

  group('the quiet link appears only where it leads somewhere else', () {
    test('never on the default path, where it duplicated the primary key', () {
      // The regression this whole change is about.
      expect(
        OnboardingLaunchActions.showExplore(
          step: OnboardingCubit.launchStep,
          replay: false,
          mode: null,
        ),
        isFalse,
      );
    });

    test('shown with a pinned transport, where it means "skip the setup"', () {
      expect(
        OnboardingLaunchActions.showExplore(
          step: OnboardingCubit.launchStep,
          replay: false,
          mode: TransferMode.bluetooth,
        ),
        isTrue,
      );
    });

    test('never on a replay', () {
      expect(
        OnboardingLaunchActions.showExplore(
          step: OnboardingCubit.launchStep,
          replay: true,
          mode: TransferMode.bluetooth,
        ),
        isFalse,
      );
    });

    test('never before the last beat', () {
      for (var step = 0; step < OnboardingCubit.launchStep; step++) {
        expect(
          OnboardingLaunchActions.showExplore(
            step: step,
            replay: false,
            mode: TransferMode.bluetooth,
          ),
          isFalse,
          reason: 'step $step is not the launch beat',
        );
      }
    });
  });

  test('the two answers can never disagree', () {
    // The failure mode that produced the duplicate: one condition updated and
    // the other left behind. The link may only ever appear on a beat whose key
    // is actually walking into a flow.
    for (final replay in const [true, false]) {
      for (final mode in [null, ...TransferMode.values]) {
        final explore = OnboardingLaunchActions.showExplore(
          step: OnboardingCubit.launchStep,
          replay: replay,
          mode: mode,
        );
        final joins = OnboardingLaunchActions.joinsAChannel(
          replay: replay,
          mode: mode,
        );
        expect(
          explore && !joins,
          isFalse,
          reason:
              'replay: $replay, mode: $mode — a second button to the same '
              'screen as the primary key',
        );
      }
    }
  });
}
