import 'package:flutter/widgets.dart';

import 'handover_transition.dart';

/// A step-to-step transition strategy for a linear flow (onboarding, a tour, a
/// wizard).
///
/// Implementations composite the beat being replaced ([leaving], null on the
/// very first beat) with the one taking its place ([incoming]) for a `0 → 1`
/// [progress] clock owned by the caller. They must resolve to a plain
/// [incoming] at the ends of that clock so an idle flow costs nothing.
///
/// The contract deliberately takes an [Animation] rather than a `double`: a
/// well-behaved implementation drives its motion straight off the animation
/// (render-object transitions, `CustomPainter.repaint`) instead of rebuilding
/// the beats every frame, which is what keeps these usable on weak GPUs.
@immutable
abstract class BeatTransition {
  const BeatTransition();

  /// [direction] is `+1` when advancing through the flow and `-1` when going
  /// back; [textDirection] mirrors the motion for RTL locales.
  Widget build({
    required Widget? leaving,
    required Widget incoming,
    required Animation<double> progress,
    required int direction,
    required TextDirection textDirection,
  });
}

/// Drop-in host for a [BeatTransition].
///
/// Give it the two beats and the clock; it resolves the ambient
/// [TextDirection], gives each beat its own [RepaintBoundary] (so the
/// compositor can reuse a cached raster instead of re-recording the panel every
/// frame) and hands everything to [transition].
///
/// The beats are ordinary widgets rebuilt by *your* build method, on your own
/// schedule — this widget never rebuilds them for the animation. Build them
/// where you build the rest of the page:
///
/// ```dart
/// BeatTransitionView(
///   progress: _stepController,
///   direction: _direction,
///   leaving: _leaving == null ? null : buildBeat(_leaving!),
///   incoming: buildBeat(_shown),
/// )
/// ```
class BeatTransitionView extends StatelessWidget {
  const BeatTransitionView({
    super.key,
    required this.progress,
    required this.incoming,
    this.leaving,
    this.direction = 1,
    this.transition = const HandoverTransition(),
  });

  /// 0 → 1 for one beat change. Drive it with an [AnimationController].
  final Animation<double> progress;

  /// The beat coming in — also the one that sizes the stage.
  final Widget incoming;

  /// The beat on its way out, or null when there is nothing to replace.
  final Widget? leaving;

  /// +1 advancing, -1 going back.
  final int direction;

  final BeatTransition transition;

  @override
  Widget build(BuildContext context) {
    final out = leaving;
    return transition.build(
      leaving: out == null ? null : RepaintBoundary(child: out),
      incoming: RepaintBoundary(child: incoming),
      progress: progress,
      direction: direction,
      textDirection: Directionality.of(context),
    );
  }
}
