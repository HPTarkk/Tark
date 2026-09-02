import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/motion/app_motion.dart';

/// Page transition for the Room journey — Landing → Rooms → lobby → channel.
///
/// The default Android builder throws the incoming page up from the bottom
/// edge, which says "a new thing appeared". These four screens are one journey
/// into a single place, so the motion says that instead: the new page rises a
/// short way and fades in over the old one, which recedes very slightly rather
/// than sliding away. The pair reads as depth — you went *further in*, not
/// somewhere else — and it makes the back gesture legible as coming back out.
///
/// [AppMotion.drawer] is the curve on purpose: almost no ease-in and a long
/// settle, so the page is already moving on the first frame the finger lifts.
Page<T> roomPage<T>(GoRouterState state, Widget child) =>
    CustomTransitionPage<T>(
      key: state.pageKey,
      child: child,
      transitionDuration: AppMotion.sheet,
      // Coming back is quicker than going in. The user already knows what is
      // behind them, so the reverse only has to get out of the way.
      reverseTransitionDuration: AppMotion.card,
      transitionsBuilder: (context, animation, secondary, child) {
        if (AppMotion.reduced(context)) {
          return FadeTransition(opacity: animation, child: child);
        }
        final incoming = CurvedAnimation(
          parent: animation,
          curve: AppMotion.drawer,
          reverseCurve: AppMotion.easeOut,
        );
        final outgoing = CurvedAnimation(
          parent: secondary,
          curve: AppMotion.drawer,
          reverseCurve: AppMotion.easeOut,
        );
        return FadeTransition(
          opacity: incoming,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.035),
              end: Offset.zero,
            ).animate(incoming),
            // The page being covered scales down by 1.5%, far too little to
            // notice as movement and just enough to read as distance. Any more
            // and it becomes a card trick.
            child: ScaleTransition(
              scale: Tween<double>(begin: 1, end: 0.985).animate(outgoing),
              child: FadeTransition(
                opacity: Tween<double>(begin: 1, end: 0.7).animate(outgoing),
                child: child,
              ),
            ),
          ),
        );
      },
    );
