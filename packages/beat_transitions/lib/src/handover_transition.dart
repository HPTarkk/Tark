import 'package:flutter/widgets.dart';

import 'beat_transition.dart';
import 'lock_reticle.dart';
import 'speed_field.dart';
import 'stage.dart';

/// The default transition: a staged **handover**, where the outgoing beat is
/// thrown off the end of the screen and the next one is brought in from the
/// start under a targeting reticle.
///
/// Unlike a slide or a cross-fade this takes its time and spends it on purpose
/// — see [Stage] for the phase map. The old panel winds up before it goes, the
/// stage is deliberately *empty* for a moment while the wind tears through it,
/// and the new panel decelerates in and lands on a damped bounce with the
/// reticle snapping onto its corners. The pause in the middle is the point: it
/// gives the change somewhere to happen instead of making the two panels trade
/// places in one motion.
///
/// The game-console read comes from stacking cheap devices rather than one
/// expensive one: anticipation and follow-through, squash-and-stretch along the
/// travel axis, a perspective turn into depth, motion trails, parallax wind, HUD
/// guide rails, a converging reticle and a lock shockwave.
///
/// ### Why it stays smooth
///
/// Every frame is a compositor operation on two cached rasters plus ~110 plain
/// `drawLine`/`drawRect` calls:
///
/// * no `MaskFilter`/`ImageFilter` blur, no `saveLayer`,
/// * no clip — the panels simply travel past the edge of the screen,
/// * no non-rectangular path work,
/// * **no widget is rebuilt for the animation.** The panels' `Transform` and
///   `Opacity` read the clock directly, and the painters repaint off the
///   animation via `CustomPainter.repaint`.
///
/// That last point matters more than the rest put together: a transition that
/// rebuilds its beats every frame pays for the whole subtree 60 times a second
/// no matter how cheap the effect on top is. For the same reason, feed it beats
/// that are *static* for the duration — a per-child entrance animation inside
/// the arriving panel defeats its raster cache and is the one thing here that
/// scales with how complex your beats are.
class HandoverTransition extends BeatTransition {
  const HandoverTransition({
    this.accent = const Color(0xFFF5853F),
    this.streakCount = 26,
    this.turn = 0.30,
    this.arc = 18,
    this.trails = 3,
    this.reticle = true,
    this.exitToEnd = true,
  });

  /// Colour of the wind, the trails and the reticle.
  final Color accent;

  /// Streaks in the parallax wind field; 0 turns the wind off.
  final int streakCount;

  /// Radians of perspective Y-rotation at full travel — the panels turn away
  /// into depth rather than sliding flat. 0 keeps them face-on.
  final double turn;

  /// Pixels the incoming panel rises through as it settles.
  final double arc;

  /// Ghost outlines trailing each panel. 0 disables them.
  final int trails;

  /// Draw the converging targeting reticle, guide rails and lock shockwave.
  final bool reticle;

  /// When true (the default, and what the choreography is built around)
  /// advancing throws the old beat toward the *end* edge and brings the new one
  /// in from the *start* edge. Flip it for the conventional reading.
  final bool exitToEnd;

  @override
  Widget build({
    required Widget? leaving,
    required Widget incoming,
    required Animation<double> progress,
    required int direction,
    required TextDirection textDirection,
  }) {
    if (leaving == null) return incoming;

    // Screen-space sign: +1 = everything travels toward the right edge.
    final ltr = textDirection == TextDirection.ltr;
    final sign =
        (exitToEnd ? 1.0 : -1.0) *
        (direction >= 0 ? 1.0 : -1.0) *
        (ltr ? 1.0 : -1.0);

    return Stack(
      // The panels are *meant* to leave the frame; anything clipping them here
      // would cut them off mid-flight at the padding edge.
      clipBehavior: Clip.none,
      children: [
        if (streakCount > 0)
          Positioned(
            left: -150,
            right: -150,
            top: -110,
            bottom: -110,
            child: SpeedField(
              progress: progress,
              sign: sign,
              color: accent,
              count: streakCount,
            ),
          ),
        if (trails > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: _Trails(
                progress: progress,
                sign: sign,
                color: accent,
                count: trails,
              ),
            ),
          ),
        // Incoming is the non-positioned child, so it sizes the stage.
        _Panel(
          progress: progress,
          sign: sign,
          turn: turn,
          arc: arc,
          incoming: true,
          child: incoming,
        ),
        Positioned.fill(
          child: IgnorePointer(
            // Let the outgoing beat keep its own height instead of being
            // stretched to the incoming one's — they are rarely the same and
            // a squashed panel is very visible while it flies out.
            child: OverflowBox(
              alignment: Alignment.center,
              minHeight: 0,
              maxHeight: double.infinity,
              child: _Panel(
                progress: progress,
                sign: sign,
                turn: turn,
                arc: arc,
                incoming: false,
                child: leaving,
              ),
            ),
          ),
        ),
        if (reticle)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: LockReticle(progress: progress, color: accent),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// How far a panel travels to clear the frame. Shared so the ghost trails stay
/// attached to the thing casting them.
double _travelFor(BuildContext context) =>
    MediaQuery.sizeOf(context).width * 1.08 + 48;

/// Hosts [MotionTrails], which needs the same travel distance the panels use.
class _Trails extends StatelessWidget {
  const _Trails({
    required this.progress,
    required this.sign,
    required this.color,
    required this.count,
  });

  final Animation<double> progress;
  final double sign;
  final Color color;
  final int count;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: MotionTrails(
        progress: progress,
        sign: sign,
        travel: _travelFor(context),
        color: color,
        count: count,
      ),
    ),
  );
}

/// One panel's flight. Rebuilds two throwaway wrapper widgets per frame and
/// nothing else — [child] is passed straight through `AnimatedBuilder`'s cache,
/// so its element (and its raster, if it is a repaint boundary) survives.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.progress,
    required this.sign,
    required this.turn,
    required this.arc,
    required this.incoming,
    required this.child,
  });

  final Animation<double> progress;
  final double sign;
  final double turn;
  final double arc;
  final bool incoming;
  final Widget child;

  /// Strength of the perspective divide. Small — enough to read as depth, not
  /// enough to make text swim.
  static const _perspective = 0.0011;

  @override
  Widget build(BuildContext context) {
    // Far enough that a centred panel is fully past the edge of the display.
    final travel = _travelFor(context);

    return AnimatedBuilder(
      animation: progress,
      child: child,
      builder: (context, prebuilt) {
        final s = Stage(progress.value);
        // Distance from rest: 0 = home, 1 = fully off frame.
        final p = incoming ? s.entry : s.exit;
        final opacity = incoming ? s.entryOpacity : s.exitOpacity;
        // Only the outgoing panel may drop out of the tree — the incoming one
        // sizes the stage and has to keep laying out even while invisible.
        if (!incoming && opacity <= 0.004) return const SizedBox.shrink();

        // Squash and stretch along the travel axis: compressed while winding
        // up, drawn out while moving, overshooting as it lands.
        final speed = incoming ? s.entrySpeed : s.exitSpeed;
        var sx = 1 + 0.13 * speed;
        var sy = 1 - 0.10 * speed;
        if (incoming) {
          sx -= 0.04 * s.settle;
          sy += 0.05 * s.settle;
        } else {
          sx -= 0.05 * s.anticipation;
          sy += 0.045 * s.anticipation;
        }
        // Recede a little into the rush so the panels read as travelling
        // through depth rather than sliding on glass.
        final recede = 1 - (incoming ? 0.10 : 0.16) * p.abs();
        sx *= recede;
        sy *= recede;

        final matrix = Matrix4.translationValues(
          sign * travel * p * (incoming ? -1 : 1),
          // Incoming arcs up into its resting place; outgoing dips away.
          arc * p * (incoming ? 1 : 0.6),
          0,
        );
        if (turn != 0) {
          matrix.multiply(
            Matrix4.identity()
              ..setEntry(3, 2, _perspective)
              ..multiply(Matrix4.rotationY(sign * turn * p)),
          );
        }
        matrix.multiply(Matrix4.diagonal3Values(sx, sy, 1));

        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform(
            transform: matrix,
            alignment: Alignment.center,
            child: prebuilt,
          ),
        );
      },
    );
  }
}
