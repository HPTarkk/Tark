import 'package:flutter/material.dart';

/// Beat-to-beat transition for the onboarding journey.
///
/// One unified motion for every boundary — a Material *shared-axis* glide along
/// the direction of travel. The outgoing beat eases a short way off and fades
/// down; the incoming beat eases in from the opposite side and fades up. Their
/// fades overlap for a brief window in the middle, so the change reads as a
/// single surface cross-dissolving and re-settling — no hard dead frame between
/// the two (which felt like a stutter), and no full-opacity ghosting either.
///
/// The travel is deliberately small (a nudge, not a swipe) and the whole thing
/// rides one easeInOutCubic, so stepping through every beat feels the same and
/// calm instead of four different tricks. [dir] is +1 advancing, -1 going back;
/// every value resolves to the exact identity transform at t == 1.
Widget buildBeatTransition({
  required int dir,
  required bool leaving,
  required double t,
  required double width,
  required Widget child,
}) {
  // A gentle fraction of the screen — enough to read as directional, never a
  // full swipe.
  final travel = (width * 0.14).clamp(28.0, 60.0);
  final glide = Curves.easeInOutCubic.transform(t);

  if (leaving) {
    // Faded out by 0.55; the incoming starts lifting at 0.35, so the pair only
    // overlaps while both are near-transparent.
    final opacity = 1 - Curves.easeIn.transform((t / 0.55).clamp(0.0, 1.0));
    return Opacity(
      opacity: opacity,
      child: Transform.translate(
        offset: Offset((-dir * travel * glide).toDouble(), 0),
        child: Transform.scale(scale: 1 - 0.02 * glide, child: child),
      ),
    );
  }

  final opacity = Curves.easeOut.transform(((t - 0.35) / 0.65).clamp(0.0, 1.0));
  return Opacity(
    opacity: opacity,
    child: Transform.translate(
      offset: Offset((dir * travel * (1 - glide)).toDouble(), 0),
      child: Transform.scale(scale: 0.98 + 0.02 * glide, child: child),
    ),
  );
}
