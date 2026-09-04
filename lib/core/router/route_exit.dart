import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaves the current route for [upPath] when there is nothing to pop.
///
/// Several of this app's screens are routinely the *only* route on the stack.
/// Quick access and the home-screen widget land straight on the channel; room
/// creation, the join scanner and the lobby's own exit all navigate with `go`,
/// which replaces the stack rather than pushing onto it. On those arrivals
/// `pop()` has nothing to pop: the control does nothing at all, and Android's
/// back gesture closes the app instead of leaving the screen.
///
/// So "out" is a **rule, not a control**. Pop when there is somewhere to pop
/// to — the user pushed their way here and expects to retrace it — and
/// otherwise go *up*, to the surface this one belongs under. The two answers
/// are never allowed to differ, which is why the on-screen control and
/// [RouteExitScope] both route through this single function.
///
/// The trap it removes is subtle and it has now been hit twice: fixing one
/// screen's dead end by sending it `go`ing somewhere else simply moves the
/// dead end to wherever it lands, because that screen is now stackless too.
/// A surface that can be reached this way needs its own answer to "out"; it
/// cannot inherit one from a navigator that has been emptied underneath it.
void exitRouteTo(BuildContext context, String upPath) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go(upPath);
  }
}

/// Gives the system back gesture the same answer the on-screen control gives.
///
/// The control is only half of it: the gesture is how most people actually
/// leave a screen, and with nothing under this route an unhandled back closed
/// the app. `canPop: false` routes both through [onExit], so the gesture and
/// the chevron cannot disagree about where "out" is.
///
/// Screens that need to *ask* before leaving — the live channel tears down a
/// transport, a keep-alive service and a microphone — own their own `PopScope`
/// with the confirmation in it rather than using this.
class RouteExitScope extends StatelessWidget {
  const RouteExitScope({required this.onExit, required this.child, super.key});

  final VoidCallback onExit;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) onExit();
    },
    child: child,
  );
}
