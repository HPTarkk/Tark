import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';

/// Hands one movement's lines over to the next — the same gesture the
/// website uses whenever a panel changes its content: what is there lifts a
/// few pixels and dissolves, quickly, then the new lines rise into place one
/// after another.
///
/// One [progress] clock (0 → 1) drives every line on both sides, so the swap
/// is a single choreographed gesture rather than a crowd of independent
/// animations, and nothing here rebuilds its children per frame: each line
/// is a `FadeTransition` plus a translate around a subtree built once.
///
/// [direction] is +1 walking forward (lines rise from below, the old ones
/// leave upward) and -1 walking back (the reverse), so going back reads as
/// going back. Reduced motion keeps the fades and the order, and drops the
/// travel.
class StepSwap extends StatelessWidget {
  const StepSwap({
    required this.progress,
    required this.incoming,
    this.leaving,
    this.direction = 1,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    super.key,
  });

  final Animation<double> progress;
  final List<Widget> incoming;
  final List<Widget>? leaving;
  final int direction;
  final CrossAxisAlignment crossAxisAlignment;

  /// The share of the clock the outgoing lines have to clear the stage.
  static const double outEnd = 0.26;

  /// When the first incoming line starts, overlapping the tail of the exit
  /// so the stage is never fully empty.
  static const double inStart = 0.2;

  /// Gap between neighbouring incoming lines, as a share of the clock.
  static const double stagger = 0.055;

  /// One incoming line's share of the clock.
  static const double inSpan = 0.5;

  /// Interval for incoming line [index].
  static Interval incomingInterval(int index) {
    final begin = (inStart + stagger * index).clamp(0.0, 1 - inSpan / 2);
    return Interval(
      begin,
      (begin + inSpan).clamp(0.0, 1.0),
      curve: AppMotion.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final rise = reduced ? 0.0 : 16.0 * direction;
    final lift = reduced ? 0.0 : -10.0 * direction;
    final out = leaving;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: crossAxisAlignment,
          children: [
            for (var i = 0; i < incoming.length; i++)
              _Line(
                animation: progress.drive(
                  CurveTween(curve: incomingInterval(i)),
                ),
                from: rise,
                child: incoming[i],
              ),
          ],
        ),
        if (out != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: crossAxisAlignment,
                  children: [
                    for (var i = 0; i < out.length; i++)
                      _Line(
                        animation: progress.drive(
                          Tween<double>(begin: 1, end: 0).chain(
                            CurveTween(
                              curve: Interval(
                                (0.012 * i).clamp(0.0, 0.1),
                                outEnd,
                                curve: AppMotion.easeOut,
                              ),
                            ),
                          ),
                        ),
                        // Reversed: at 0 the line is gone, so "from" is
                        // where it leaves *to*.
                        from: lift,
                        child: out[i],
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One line of a movement: fades with [animation] and travels from [from]
/// pixels below its place (negative: above) to rest.
class _Line extends StatelessWidget {
  const _Line({
    required this.animation,
    required this.from,
    required this.child,
  });

  final Animation<double> animation;
  final double from;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final faded = FadeTransition(opacity: animation, child: child);
    if (from == 0) return faded;
    return AnimatedBuilder(
      animation: animation,
      child: faded,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, from * (1 - animation.value)),
        child: child,
      ),
    );
  }
}
