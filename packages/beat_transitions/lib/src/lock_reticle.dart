import 'package:flutter/widgets.dart';

import 'stage.dart';

/// The HUD chrome of a beat handover: guide rails across the empty stage, a
/// targeting reticle that closes on the landing zone while the new panel is
/// still inbound, and a shockwave when it locks.
///
/// This is what turns a slide into an *acquisition*. It also does the real work
/// of making the deliberate pause mid-transition read as intent rather than
/// lag: with nothing on the stage but wind, the converging brackets tell you
/// something is arriving and exactly where.
///
/// Painted over the panels, sized to the incoming panel's box. Costs about 20
/// `drawLine`/`drawRect` calls and paints nothing at all outside a transition.
class LockReticle extends CustomPainter {
  LockReticle({required this.progress, required this.color})
    : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  /// How far outside the panel the brackets start, in px.
  static const _spread = 44.0;

  /// Length of each bracket arm.
  static const _arm = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0.0 || t >= 1.0) return;
    final s = Stage(t);

    _paintRails(canvas, size, s);

    final alpha = s.reticleAlpha;
    if (alpha > 0.01) {
      // Brackets ride in from outside and land exactly on the corners.
      final out = _spread * (1 - s.reticle);
      final rect = Rect.fromLTWH(0, 0, size.width, size.height).inflate(out);
      // The lock flash rides on top of the base alpha, so the corners punch
      // at the moment the panel comes to rest.
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + 0.8 * s.impact
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(
          alpha: (alpha * (0.55 + 0.45 * s.impact)).clamp(0.0, 1.0),
        );
      _bracket(canvas, rect.topLeft, 1, 1, paint);
      _bracket(canvas, rect.topRight, -1, 1, paint);
      _bracket(canvas, rect.bottomLeft, 1, -1, paint);
      _bracket(canvas, rect.bottomRight, -1, -1, paint);
    }

    // Shockwave: a single ring pushing outward as the panel settles.
    if (s.impact > 0.01) {
      final wave = Rect.fromLTWH(
        0,
        0,
        size.width,
        size.height,
      ).inflate(4 + 46 * (1 - s.impact));
      canvas.drawRect(
        wave,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: 0.35 * s.impact),
      );
    }
  }

  /// Two arms meeting at [corner]; [sx]/[sy] point them inward.
  void _bracket(Canvas canvas, Offset corner, double sx, double sy, Paint p) {
    canvas.drawLine(corner, corner + Offset(_arm * sx, 0), p);
    canvas.drawLine(corner, corner + Offset(0, _arm * sy), p);
  }

  /// Two hairlines running the width of the stage at the panel's top and
  /// bottom edges — the track the beats travel along.
  void _paintRails(Canvas canvas, Size size, Stage s) {
    final rails = s.rails;
    if (rails < 0.01) return;
    final paint = Paint()
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.22 * rails);
    // Grown from the centre outward so they sweep open rather than blink on.
    final half = size.width * 0.5 * (0.25 + 0.95 * rails);
    final cx = size.width / 2;
    for (final y in [0.0, size.height]) {
      canvas.drawLine(Offset(cx - half, y), Offset(cx + half, y), paint);
    }
  }

  @override
  bool shouldRepaint(LockReticle old) => old.color != color;
}

/// Ghost outlines strung out behind each panel along its travel — the cheapest
/// honest motion blur there is: a few stroked rectangles, no filter, no layer.
///
/// Painted behind the panels and in front of the wind. [travel] must be the
/// same distance the panels use, or the ghosts detach from the thing casting
/// them.
class MotionTrails extends CustomPainter {
  MotionTrails({
    required this.progress,
    required this.sign,
    required this.travel,
    required this.color,
    this.count = 3,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final double sign;
  final double travel;
  final Color color;
  final int count;

  /// Px between successive ghosts at full speed.
  static const _spacing = 34.0;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0.0 || t >= 1.0) return;
    final s = Stage(t);
    final box = Rect.fromLTWH(0, 0, size.width, size.height);

    // Both panels move in +sign, so both trail toward -sign.
    _streak(canvas, box, sign * travel * s.exit, s.exitSpeed, s.exitOpacity);
    _streak(canvas, box, -sign * travel * s.entry, s.entrySpeed, s.entryOpacity);
  }

  void _streak(Canvas canvas, Rect box, double panelX, double speed, double opacity) {
    if (speed < 0.05 || opacity < 0.05) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (var i = 1; i <= count; i++) {
      final f = i / count;
      final ghost = box
          .shift(Offset(panelX - sign * f * _spacing * speed, 0))
          .deflate(4 * f);
      paint.color = color.withValues(
        alpha: (0.30 * speed * opacity * (1 - f * 0.7)).clamp(0.0, 1.0),
      );
      canvas.drawRect(ghost, paint);
    }
  }

  @override
  bool shouldRepaint(MotionTrails old) =>
      old.sign != sign ||
      old.travel != travel ||
      old.color != color ||
      old.count != count;
}
