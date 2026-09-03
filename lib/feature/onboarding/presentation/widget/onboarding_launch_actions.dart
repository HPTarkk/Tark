import '../../../transfer/domain/entity/transfer_mode.dart';
import '../manager/onboarding_cubit.dart';

/// What the final beat offers, and what it is allowed to call it.
///
/// Pulled out of the page as a table rather than left as two conditions
/// buried in build methods, because the two answers have to agree: the moment
/// the primary key stops walking into a transport flow, the secondary link
/// stops leading anywhere the key does not — and a page that got one of those
/// right and the other wrong shipped two differently-worded buttons that took
/// the user to the identical screen.
abstract final class OnboardingLaunchActions {
  /// Whether the primary key really walks into a channel setup flow.
  ///
  /// Only with a transport pinned. On AUTOMATIC — which the transport beat
  /// pre-selects, and which almost every install keeps — there is nothing to
  /// walk: the advisor needs an intent, and the only thing that supplies one
  /// is the user tapping START or JOIN on the room screen. So the key finishes
  /// setup and lands there, and has to say so.
  static bool joinsAChannel({
    required bool replay,
    required TransferMode? mode,
  }) => !replay && mode != null;

  /// Whether the quiet "look around first" link is worth showing.
  ///
  /// Exactly when it goes somewhere the primary key does not. With no pinned
  /// transport both land on the room screen, so the link is a second button to
  /// the same place — which is what it was, on the default path, for every
  /// first run.
  static bool showExplore({
    required int step,
    required bool replay,
    required TransferMode? mode,
  }) =>
      step == OnboardingCubit.launchStep &&
      joinsAChannel(replay: replay, mode: mode);
}
