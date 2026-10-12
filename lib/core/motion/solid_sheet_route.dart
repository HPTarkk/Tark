import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'app_motion.dart';

/// A full-screen page that arrives and leaves as one **solid sheet**.
///
/// The screen that opens it (Landing, the saved-room list) does not fade away
/// and the sheet never fades in over it. Two screens dissolving through each
/// other is exactly what made room creation's exit look broken: for a third
/// of a second the list showed through the half-transparent form, and neither
/// screen was legible. Here, at every frame, each pixel belongs to exactly one
/// opaque surface:
///
/// * the sheet rises from the bottom edge, fully opaque, its top corners
///   rounding while it travels so it reads as a physical card rather than a
///   wipe;
/// * the screen underneath recedes — scales back a few percent, rounds its own
///   corners and dims under a scrim — so it reads as *behind* the sheet;
/// * leaving plays the same story backwards: the sheet drops away as a solid
///   card while the screen behind it rises back up to full size.
///
/// The receding is driven through [delegatedTransition], so the route below
/// moves in lock-step with this one whatever transition it uses itself.
///
/// Reduced motion keeps the meaning without the travel: a dip through the
/// app's background colour. The outgoing screen settles into a flat surface
/// first, then the incoming one resolves out of it — still never two screens
/// at once.
class SolidSheetRoute<T> extends PageRoute<T> {
  SolidSheetRoute({required WidgetBuilder builder, super.settings})
    : _builder = builder;

  /// Page-based form, built by [SolidSheetPage.createRoute].
  SolidSheetRoute._page(SolidSheetPage<T> page)
    : _builder = null,
      super(settings: page);

  final WidgetBuilder? _builder;

  /// How far the screen behind recedes. Small: it must read as "behind",
  /// not as a thumbnail.
  static const double recededScale = 0.94;

  /// Corner radius the sheet wears while it travels, and the screen behind
  /// wears while it is receded.
  static const double travelRadius = 28;

  static const Duration _enter = Duration(milliseconds: 520);
  static const Duration _exit = Duration(milliseconds: 420);
  static const Duration _dip = Duration(milliseconds: 240);

  /// The scrim over the receded screen at full depth.
  static const double _scrim = 0.55;

  /// Leaving starts fast and settles as the sheet clears the bottom edge —
  /// [AppMotion.drawer] played backwards would start slow, which reads as
  /// the app hesitating after the tap.
  static const Curve _reverseCurve = FlippedCurve(AppMotion.drawer);

  bool get _reduced {
    final context = navigator?.context;
    return context != null && AppMotion.reduced(context);
  }

  @override
  Duration get transitionDuration => _reduced ? _dip : _enter;

  @override
  Duration get reverseTransitionDuration => _reduced ? _dip : _exit;

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final page = settings;
    final Widget child = page is SolidSheetPage<T>
        ? page.child
        : _builder!(context);
    return Semantics(scopesRoute: true, explicitChildNodes: true, child: child);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) {
      return _DipTransition(animation: animation, child: child);
    }
    final travel = CurvedAnimation(
      parent: animation,
      curve: AppMotion.drawer,
      reverseCurve: _reverseCurve,
    );
    return _SheetTransition(animation: travel, child: child);
  }

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _recede;

  /// What the route *below* does while this one arrives or leaves.
  static Widget? _recede(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    // Reduced motion: the screen below stays put; the dip happens on top.
    if (AppMotion.reduced(context)) return child;
    final depth = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AppMotion.drawer,
      reverseCurve: _reverseCurve,
    );
    return _RecedeTransition(depth: depth, child: child);
  }
}

/// [SolidSheetRoute] for declarative navigation (GoRouter's `pageBuilder`).
class SolidSheetPage<T> extends Page<T> {
  const SolidSheetPage({
    required this.child,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  final Widget child;

  @override
  Route<T> createRoute(BuildContext context) => SolidSheetRoute<T>._page(this);
}

class _SheetTransition extends AnimatedWidget {
  const _SheetTransition({required Animation<double> animation, this.child})
    : super(listenable: animation);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    // The tree keeps one shape at every value — only paint parameters
    // change — so settling never rebuilds the page under it. At rest the
    // clip is off and the scrim and shadow are fully transparent.
    final settled = t >= 1;
    final radius = Radius.circular(
      lerpDouble(SolidSheetRoute.travelRadius, 0, t * t)!,
    );
    final corners = BorderRadius.vertical(top: radius);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The scrim lives on this route, under the sheet and over the screen
        // behind it, so the dimming and the travel can never drift apart.
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(
              alpha: settled ? 0 : SolidSheetRoute._scrim * t,
            ),
          ),
        ),
        FractionalTranslation(
          translation: Offset(0, 1 - t),
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: corners,
              // A hairline of the accent along the leading edge while the
              // sheet travels: the eye tracks one bright line, not a slab.
              border: Border(
                top: settled
                    ? BorderSide.none
                    : BorderSide(
                        color: AppColors.amber.withValues(
                          alpha: 0.22 * (1 - t),
                        ),
                      ),
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: corners,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: settled ? 0 : 0.4 * (1 - t * t),
                    ),
                    blurRadius: 24,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: corners,
                clipBehavior: settled ? Clip.none : Clip.antiAlias,
                // Opaque backing: whatever the page draws (a translucent
                // mesh, a transparent Scaffold), nothing behind it shows.
                child: ColoredBox(color: AppColors.background, child: child),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecedeTransition extends AnimatedWidget {
  const _RecedeTransition({required Animation<double> depth, this.child})
    : super(listenable: depth);

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final d = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // What shows around the receded screen's corners: a deep backdrop,
        // the same in both themes, rather than whatever the window holds.
        ColoredBox(color: d <= 0 ? Colors.transparent : Colors.black),
        Transform.scale(
          scale: lerpDouble(1, SolidSheetRoute.recededScale, d),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              SolidSheetRoute.travelRadius * d,
            ),
            clipBehavior: d <= 0 ? Clip.none : Clip.antiAlias,
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Reduced motion: the old screen dips into the background colour, then the
/// new one resolves out of it. Both halves are against an opaque surface.
class _DipTransition extends AnimatedWidget {
  const _DipTransition({required Animation<double> animation, this.child})
    : super(listenable: animation);

  final Widget? child;

  static const _cover = Interval(0, 0.5, curve: Curves.easeOut);
  static const _reveal = Interval(0.5, 1, curve: Curves.easeOut);

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value.clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: Opacity(
            opacity: t >= 1 ? 0 : _cover.transform(t),
            child: ColoredBox(color: AppColors.background),
          ),
        ),
        Opacity(opacity: _reveal.transform(t), child: child),
      ],
    );
  }
}
