import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Asks the destination route to *continue* the screen it was opened from
/// instead of sliding in as a new page.
///
/// Passed as GoRouter `extra` (it never goes into a URL). Routes that know it
/// build a [ContinuityPage]; every other way into the same route keeps the
/// app's standard transition, so a caller opts in per navigation, not per
/// route.
@immutable
class ContinuityHandoff {
  const ContinuityHandoff();
}

/// A page that arrives as a continuation of the one beneath it.
///
/// Both screens stand on the same backdrop — MeshBackground draws the
/// identical frame on every screen that shows it — so the transition moves
/// nothing behind the content: the new screen simply dissolves in over the
/// old one, which stays fully opaque underneath (so the backdrop never dips
/// through a half-transparent pair), while
///
/// * the old screen's *foreground* recedes — it eases forward and dissolves,
///   as if the camera walked through it — wherever that screen wraps its
///   foreground in a [ContinuityRecede];
/// * a shared [Hero] (the Room formation, say) flies across;
/// * the new screen plays its own entrance once it has arrived.
///
/// That reads as one surface rearranging itself rather than a page being
/// pushed. It also replaces whatever exit the screen underneath would
/// otherwise play (a sliding parallax) through
/// [ModalRoute.delegatedTransition]. Reduced motion keeps the dissolve and
/// drops the recede's travel.
class ContinuityPage<T> extends Page<T> {
  const ContinuityPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => _ContinuityRoute<T>(this);
}

class _ContinuityRoute<T> extends PageRoute<T> {
  _ContinuityRoute(ContinuityPage<T> page) : super(settings: page);

  ContinuityPage<T> get _page => settings as ContinuityPage<T>;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 520);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _handOver;

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
    // Another continuity page on top shares this route's delegated
    // transition, so it is not *received* (see TransitionRoute.didChangeNext)
    // and its hand-over is wired here instead.
    return _handOver(
      context,
      animation,
      secondaryAnimation,
      false,
      FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.7, curve: AppMotion.easeOut),
          reverseCurve: const Interval(0.15, 1, curve: Curves.easeIn),
        ),
        child: child,
      ),
    );
  }

  /// What the screen underneath does while a continuation settles over it:
  /// nothing to the screen as a whole — it stays put and opaque — but its
  /// [ContinuityRecede] is handed the clock.
  static Widget _handOver(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => _RecedeScope(
    animation: secondaryAnimation,
    child: child ?? const SizedBox.shrink(),
  );
}

class _RecedeScope extends InheritedWidget {
  const _RecedeScope({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_RecedeScope old) => old.animation != animation;
}

/// The part of a screen that recedes when a [ContinuityPage] continues it —
/// the content, not the backdrop. Without a continuation on top it is
/// transparent: it paints [child] as it is.
class ContinuityRecede extends StatelessWidget {
  const ContinuityRecede({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_RecedeScope>();
    if (scope == null) return child;
    final progress = scope.animation;
    final faded = FadeTransition(
      opacity: progress.drive(
        Tween<double>(begin: 1, end: 0).chain(
          CurveTween(curve: const Interval(0, 0.6, curve: AppMotion.easeOut)),
        ),
      ),
      child: child,
    );
    if (AppMotion.reduced(context)) return faded;
    return ScaleTransition(
      scale: progress.drive(
        Tween<double>(
          begin: 1,
          end: 1.05,
        ).chain(CurveTween(curve: AppMotion.easeOut)),
      ),
      child: faded,
    );
  }
}
