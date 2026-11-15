import 'package:flutter/material.dart';

import '../motion/app_motion.dart';

/// Swaps [child] whenever [icon] changes: the new one springs up from a
/// little below its size with a slight twist, the old one sinks and fades.
///
/// Shared by the Room's topic glyph and its monogram, so a topic arrives the
/// same way everywhere it is drawn.
class IconPopSwitcher extends StatelessWidget {
  const IconPopSwitcher({
    required this.icon,
    required this.reduced,
    required this.child,
    this.alignment = AlignmentDirectional.centerStart,
    super.key,
  });

  /// What [child] shows; a change of it is what animates.
  final Object? icon;
  final bool reduced;
  final Widget child;

  /// Where the two icons sit while they cross.
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: reduced ? Duration.zero : AppMotion.sheet,
    reverseDuration: reduced ? Duration.zero : AppMotion.chip,
    // The overshoot lives in the scale and twist below: the switcher's own
    // curve feeds the fade too, and an opacity cannot pass 1.
    switchInCurve: Curves.linear,
    switchOutCurve: AppMotion.leaving,
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    transitionBuilder: (child, animation) {
      final spring = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
      );
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.6, curve: Curves.easeOut),
        ),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.55, end: 1).animate(spring),
          child: RotationTransition(
            turns: Tween<double>(begin: -0.08, end: 0).animate(spring),
            child: child,
          ),
        ),
      );
    },
    child: KeyedSubtree(key: ValueKey<Object?>(icon), child: child),
  );
}
