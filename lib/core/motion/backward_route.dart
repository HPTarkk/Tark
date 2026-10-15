import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Marks a navigation as going *back* — out of a screen, up to the surface it
/// belongs under — when it cannot be a pop.
///
/// Passed as GoRouter `extra` (never in a URL) by [goBackTo]. Several of the
/// app's screens are the only route on the stack (quick access, the home
/// widget, every `go` that replaced the stack), so "out" from them is a `go`
/// to the screen above. A plain `go` is a push: the destination slid in from
/// the reading end, exactly as if the user had moved *forward* into it. Going
/// back looked like going deeper. Routes that know this marker build a
/// [BackwardPage] instead, which plays the mirror of a push.
@immutable
class BackwardHandoff {
  const BackwardHandoff();
}

/// A page that arrives the way a pop reveals the page under it.
///
/// Forward and back are a single axis that follows the reading direction
/// (see the spatial rules in [AppMotion]): a push brings the new page in from
/// the reading end while the old one drifts towards the reading start; a pop
/// moves everything the other way. When "back" has to be a replacement
/// rather than a pop, this page keeps that promise: it enters from the
/// reading **start** while the screen it replaces drifts a third of the way
/// towards the reading **end** and dims — the same direction of travel, the
/// same timing and curve family, as the platform's own pop. Mirrored in RTL,
/// like every horizontal transition in the app.
///
/// Once it has arrived it behaves like any other page: a page pushed over it
/// later parallaxes it with the app's standard transition, and popping back
/// to it reverses that.
///
/// Reduced motion keeps the fade and drops the travel, as the standard
/// transition does.
class BackwardPage<T> extends Page<T> {
  const BackwardPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _BackwardRoute<T>(this);
}

class _BackwardRoute<T> extends PageRoute<T> {
  _BackwardRoute(BackwardPage<T> page) : super(settings: page);

  BackwardPage<T> get _page => settings as BackwardPage<T>;

  /// The platform pop's timing, so a back that had to be a replacement
  /// takes as long as one that did not.
  static const _standard = AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _standard.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _standard.reverseTransitionDuration;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => backwardExit;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _page.child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Whatever is pushed over this page later moves it the standard way.
    final settled = _standard.buildTransitions<T>(
      this,
      context,
      kAlwaysCompleteAnimation,
      secondaryAnimation,
      child,
    );
    return backwardEntrance(context, animation, settled);
  }

  /// This page's own arrival: in from the reading start.
  static Widget backwardEntrance(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return SlideTransition(
      position: CurvedAnimation(
        parent: animation,
        curve: AppMotion.drawer,
        reverseCurve: AppMotion.drawer.flipped,
      ).drive(Tween(begin: const Offset(-1, 0), end: Offset.zero)),
      textDirection: Directionality.of(context),
      child: _EdgeShadow(animation: animation, child: child),
    );
  }

  /// What the replaced screen does meanwhile: it drifts a third of the way
  /// towards the reading end and dims, the way the page under a pop moves.
  static Widget backwardExit(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    final page = child ?? const SizedBox.shrink();
    if (AppMotion.reduced(context)) return page;
    final drift = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AppMotion.drawer,
      reverseCurve: AppMotion.drawer.flipped,
    );
    return SlideTransition(
      position: drift.drive(
        Tween(begin: Offset.zero, end: const Offset(1 / 3, 0)),
      ),
      textDirection: Directionality.of(context),
      child: AnimatedBuilder(
        animation: drift,
        child: page,
        builder: (context, child) => Stack(
          fit: StackFit.passthrough,
          children: [
            child!,
            if (drift.value > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.2 * drift.value),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A soft shadow along the arriving page's trailing edge — the edge it leads
/// with — so it reads as a sheet laid over the old screen, the same cue the
/// platform push draws on its leading edge. Gone once the page has arrived.
class _EdgeShadow extends AnimatedWidget {
  const _EdgeShadow({required Animation<double> animation, required this.child})
    : super(listenable: animation);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    if (t >= 1 || t <= 0) return child;
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        child,
        PositionedDirectional(
          top: 0,
          bottom: 0,
          end: -14,
          width: 14,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: AlignmentDirectional.centerStart,
                  end: AlignmentDirectional.centerEnd,
                  colors: [
                    Colors.black.withValues(alpha: 0.18 * (1 - t)),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
