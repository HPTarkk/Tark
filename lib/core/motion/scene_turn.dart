import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_motion.dart';

/// How a [SceneTurn] moves from one state to the next. Each fits a different
/// kind of change, so a screen picks the one that says what is happening.
enum SceneMotion {
  /// The card turns over on its vertical axis: the same object showing its
  /// other face. For a swap between two equal sides (show a code / scan
  /// one), never for going deeper into a flow.
  turn,

  /// Shared axis: the leaving state slides back and fades, the next one
  /// comes in from the reading end. For stepping forward or back through a
  /// flow (lobby, connecting, the call), matching the page transitions.
  axis,

  /// Fade through: the leaving state fades out, the next one grows up out of
  /// it. For a change of state in place (a wait becoming a result, a phase
  /// inside one page).
  through,
}

/// Moves one state of a screen into the next as one continuous motion,
/// chosen to fit the change ([SceneMotion]): a turn for two equal sides, a
/// shared-axis step through a flow, a fade-through for a change in place.
///
/// The arriving state's lines re-flow in a short stagger ([SceneReflow]).
/// [scene] names the state: a new value moves, the same value updates in
/// place and keeps its state. [depth] says which way: a deeper state (the
/// lobby to a connection, a connection to the call) moves towards the
/// reading end, a shallower one back; equal depths move forward. Mirrors in
/// right-to-left.
///
/// Under reduced motion it is a plain, short crossfade.
///
/// Cost: two transformed layers for one beat, then nothing; the controller is
/// idle between changes.
class SceneTurn extends StatefulWidget {
  const SceneTurn({
    required this.scene,
    required this.child,
    this.depth = 0,
    this.fill = true,
    this.alignment = Alignment.topCenter,
    this.motion = SceneMotion.turn,
    this.quietFrom = const {},
    super.key,
  });

  /// The kind of change this is.
  final SceneMotion motion;

  /// Scenes that are only a wait: leaving one of them is always a
  /// [SceneMotion.through], so content arriving is never thrown in sideways.
  final Set<Object> quietFrom;

  /// The state [child] shows.
  final Object scene;
  final Widget child;

  /// How far in this state is, for the direction of the turn.
  final int depth;

  /// Whether the two states fill the space (a whole screen) or are sized by
  /// their content and pinned at [alignment] while they overlap.
  final bool fill;
  final AlignmentGeometry alignment;

  static const duration = Duration(milliseconds: 760);

  /// How far the state around [context] has arrived: 0..1 while it turns in,
  /// complete otherwise.
  static Animation<double> arrivalOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SceneTurnScope>()?.arrival ??
      kAlwaysCompleteAnimation;

  @override
  State<SceneTurn> createState() => _SceneTurnState();
}

class _SceneTurnState extends State<SceneTurn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: SceneTurn.duration,
    value: 1,
  );

  Object? _outgoingScene;
  Widget? _outgoing;

  /// +1 turning forward, -1 back.
  double _direction = 1;

  /// The motion of the change running now.
  SceneMotion _motion = SceneMotion.turn;

  late final Animation<double> _arrivalAfterTurn = CurvedAnimation(
    parent: _t,
    curve: const Interval(0.5, 1),
  );
  late final Animation<double> _arrivalEarly = CurvedAnimation(
    parent: _t,
    curve: const Interval(0.3, 1),
  );

  Animation<double> get _arrival =>
      _motion == SceneMotion.turn ? _arrivalAfterTurn : _arrivalEarly;

  @override
  void initState() {
    super.initState();
    _t.addStatusListener((status) {
      if (status == AnimationStatus.completed && _outgoing != null) {
        setState(() {
          _outgoing = null;
          _outgoingScene = null;
        });
      }
    });
  }

  @override
  void didUpdateWidget(SceneTurn old) {
    super.didUpdateWidget(old);
    if (old.scene == widget.scene) return;
    _outgoingScene = old.scene;
    _outgoing = old.child;
    _direction = widget.depth < old.depth ? -1 : 1;
    _motion = widget.quietFrom.contains(old.scene)
        ? SceneMotion.through
        : widget.motion;
    _t.duration = AppMotion.reduced(context)
        ? AppMotion.card
        : switch (_motion) {
            SceneMotion.turn => SceneTurn.duration,
            SceneMotion.axis => const Duration(milliseconds: 480),
            SceneMotion.through => const Duration(milliseconds: 420),
          };
    _t.forward(from: 0);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  Widget _layer(Object scene, Widget child, {required bool incoming}) {
    final reduced = AppMotion.reduced(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final dir = _direction * (rtl ? -1.0 : 1.0);
    final turning = _outgoing != null && !reduced;
    final layer = _SceneTurnScope(
      arrival: turning && incoming ? _arrival : kAlwaysCompleteAnimation,
      child: AnimatedBuilder(
        animation: _t,
        child: child,
        builder: (context, child) {
          // One shape of tree at every frame, so the state's own widgets
          // keep their state through the turn and after it.
          final t = _t.value;
          var visible = true;
          var opacity = 1.0;
          var transform = Matrix4.identity();
          if (_t.isAnimating || t < 1) {
            if (reduced) {
              opacity = incoming ? t : 1 - t;
            } else if (_motion != SceneMotion.turn) {
              // Out over the first third, in over the rest; the two overlap
              // only where both are nearly clear.
              final out = _span(t, 0, 0.35);
              final inn = Curves.easeOutCubic.transform(_span(t, 0.25, 1));
              visible = incoming || t < 0.35;
              opacity = incoming
                  ? Curves.easeOut.transform(_span(t, 0.25, 0.8))
                  : 1 - Curves.easeIn.transform(out);
              if (_motion == SceneMotion.axis) {
                final travel = 36.0 * dir;
                final dx = incoming
                    ? travel * (1 - inn)
                    : -travel * Curves.easeInCubic.transform(out);
                transform = Matrix4.translationValues(dx, 0, 0);
              } else {
                final scale = incoming ? 0.92 + 0.08 * inn : 1 - 0.03 * out;
                transform = Matrix4.diagonal3Values(scale, scale, 1);
              }
            } else if (incoming && t < 0.5) {
              // In the tree, and taking taps, from the first frame; unseen
              // until its half.
              opacity = 0;
            } else if (incoming) {
              final p = Curves.easeOutCubic.transform(_span(t, 0.5, 1));
              final scale = 0.94 + 0.06 * p;
              opacity = 0.35 + 0.65 * _span(t, 0.5, 0.85);
              transform = Matrix4.identity()
                ..setEntry(3, 2, 0.0011)
                ..rotateY(-dir * (1 - p) * math.pi / 2)
                ..scaleByDouble(scale, scale, 1, 1);
            } else {
              // Offstage once it is edge-on.
              visible = t < 0.5;
              final p = Curves.easeInCubic.transform(_span(t, 0, 0.5));
              final scale = 1 - 0.06 * p;
              opacity = 1 - 0.65 * _span(t, 0, 0.45);
              transform = Matrix4.identity()
                ..setEntry(3, 2, 0.0011)
                ..rotateY(dir * p * math.pi / 2)
                ..scaleByDouble(scale, scale, 1, 1);
            }
          }
          return Offstage(
            offstage: !visible,
            child: IgnorePointer(
              ignoring: !incoming,
              child: Opacity(
                opacity: opacity.clamp(0.0, 1.0),
                child: Transform(
                  alignment: Alignment.center,
                  transform: transform,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
    return KeyedSubtree(key: ValueKey(scene), child: layer);
  }

  @override
  Widget build(BuildContext context) {
    final outgoing = _outgoing;
    final outgoingScene = _outgoingScene;
    return Stack(
      fit: widget.fill ? StackFit.expand : StackFit.loose,
      alignment: widget.alignment,
      children: [
        if (outgoing != null && outgoingScene != null)
          _layer(outgoingScene, outgoing, incoming: false),
        _layer(widget.scene, widget.child, incoming: true),
      ],
    );
  }
}

class _SceneTurnScope extends InheritedWidget {
  const _SceneTurnScope({required this.arrival, required super.child});

  final Animation<double> arrival;

  @override
  bool updateShouldNotify(_SceneTurnScope old) => old.arrival != arrival;
}

/// One line of a state re-flowing in as it turns into view, [index] places
/// down the stagger. Does nothing outside a [SceneTurn]'s turn.
class SceneReflow extends StatelessWidget {
  const SceneReflow({required this.index, required this.child, super.key});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final arrival = SceneTurn.arrivalOf(context);
    // The same shape whether or not a turn is running, so [child] keeps its
    // state when the turn ends.
    return AnimatedBuilder(
      animation: arrival,
      child: child,
      builder: (context, child) {
        final start = 0.15 + index * 0.13;
        final p = Curves.easeOutBack.transform(
          _span(arrival.value, start, math.min(1, start + 0.55)),
        );
        return Opacity(
          opacity: p.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, AppMotion.rise * 1.4 * (1 - p)),
            child: child,
          ),
        );
      },
    );
  }
}

double _span(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);
