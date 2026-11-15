import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'solid_sheet_route.dart';

/// Whether the screen has stopped moving: no route is sliding in or out, no
/// back swipe is under someone's thumb, and no sheet or dialog sits on top.
///
/// Something that wants to rise over the app on its own (an announcement)
/// waits for this instead of guessing with a timer, so it never lands in the
/// middle of a page transition or on top of a question already being asked.
///
/// Attached to the app's root navigator once ([RouteCalm.instance], in the
/// router's observers). A navigator observer can only watch one navigator.
class RouteCalm extends NavigatorObserver {
  RouteCalm();

  /// The app's own, wired into the router.
  static final RouteCalm instance = RouteCalm();

  final _stack = <Route<dynamic>>[];
  final _moving =
      <Route<dynamic>, (Animation<double>, AnimationStatusListener)>{};
  bool _gesture = false;
  final ValueNotifier<bool> _calm = ValueNotifier(true);

  /// True when nothing is moving and nothing is open over the current page.
  ValueListenable<bool> get calm => _calm;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _watch(route, AnimationStatus.completed);
    _update();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _watch(route, AnimationStatus.dismissed);
    _update();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Removed without a pop: it leaves at once, with no transition of its
    // own to wait for.
    _stack.remove(route);
    _unwatch(route);
    _update();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final at = _stack.indexOf(oldRoute);
      _unwatch(oldRoute);
      if (at >= 0) _stack.removeAt(at);
      if (newRoute != null) {
        _stack.insert(at >= 0 ? at : _stack.length, newRoute);
      }
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
    if (newRoute != null) _watch(newRoute, AnimationStatus.completed);
    _update();
  }

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _gesture = true;
    _update();
  }

  @override
  void didStopUserGesture() {
    _gesture = false;
    _update();
  }

  /// Follows [route]'s own transition until it reaches [end] (or turns back
  /// to rest at the other end, when a push is interrupted by a pop).
  void _watch(Route<dynamic> route, AnimationStatus end) {
    _unwatch(route);
    if (route is! TransitionRoute) return;
    final animation = route.animation;
    if (animation == null || animation.isCompleted && end.isCompleted) return;
    if (animation.isDismissed && end.isDismissed) return;
    void listener(AnimationStatus status) {
      // A hero flight measures the new page offstage first, standing its
      // animation in for "complete" for that one frame: that is not the
      // transition ending.
      if (status.isAnimating || route is ModalRoute && route.offstage) return;
      _unwatch(route);
      _update();
    }

    animation.addStatusListener(listener);
    _moving[route] = (animation, listener);
  }

  void _unwatch(Route<dynamic> route) {
    final watched = _moving.remove(route);
    if (watched == null) return;
    try {
      watched.$1.removeStatusListener(watched.$2);
    } catch (_) {
      // Already disposed with its route: nothing left to stop listening to.
    }
  }

  void _update() {
    final top = _stack.isEmpty ? null : _stack.last;
    // A solid sheet (creating a Room) is a page route, but it is a flow in
    // progress all the same.
    _calm.value =
        _moving.isEmpty &&
        !_gesture &&
        top is! PopupRoute &&
        top is! SolidSheetRoute;
  }

  /// Back to an empty navigator, for tests that reuse [instance].
  @visibleForTesting
  void reset() {
    for (final route in _moving.keys.toList()) {
      _unwatch(route);
    }
    _stack.clear();
    _gesture = false;
    _update();
  }
}

/// Held by a screen while its own entrance choreography is still playing
/// (Home's logo docking and sections rising, and the question it may ask
/// straight after), so that nothing rises over it mid-motion.
///
/// A count rather than a flag, so two screens holding at once (one pushed
/// over another) never release each other. Every [hold] returns its own
/// release; calling it more than once is harmless.
abstract final class EntranceHold {
  static final ValueNotifier<int> _held = ValueNotifier(0);

  /// How many entrances are still playing.
  static ValueListenable<int> get held => _held;

  static VoidCallback hold() {
    _held.value++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _held.value--;
    };
  }
}
