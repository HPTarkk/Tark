import 'package:flutter/material.dart';

/// Starts in-page choreography only once its route has finished arriving.
/// No guessed delay: custom transitions and initial routes share this contract.
mixin RouteArrival<T extends StatefulWidget> on State<T> {
  Animation<double>? _arrivalAnimation;
  bool _arrived = false;
  bool _queuedArrival = false;

  void onRouteArrived();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _arrivalAnimation) {
      _arrivalAnimation?.removeStatusListener(_routeStatus);
      _arrivalAnimation = animation;
      animation?.addStatusListener(_routeStatus);
    }
    _tryArrival();
  }

  void _routeStatus(AnimationStatus _) => _tryArrival();

  bool get _visible =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      (_arrivalAnimation == null ||
          _arrivalAnimation!.status == AnimationStatus.completed);

  void _tryArrival() {
    if (_arrived || _queuedArrival || !_visible) return;
    _queuedArrival = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queuedArrival = false;
      if (_arrived || !_visible) return;
      _arrived = true;
      onRouteArrived();
    });
  }

  @override
  void dispose() {
    _arrivalAnimation?.removeStatusListener(_routeStatus);
    super.dispose();
  }
}
