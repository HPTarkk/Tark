import 'dart:math';

import 'package:flutter/widgets.dart';

import 'stage.dart';

/// The wind that rushes past while a beat is thrown across the stage.
///
/// A depth-sorted field of streaks streaming in the direction of travel: near
/// ones are long, fast and bright, far ones short, slow and dim, so the layer
/// reads as *parallax depth being crossed at speed* rather than a flat wipe.
/// Every streak is stretched by the instantaneous speed of the panels, so the
/// field snaps taut at mid-transition and collapses to nothing at both ends —
/// the whole layer is invisible (and free) while the flow sits still.
///
/// Deliberately cheap: the streak table is generated once from a fixed seed and
/// shared by every transition, the painter repaints straight off the animation
/// (no widget ever rebuilds), and a frame is ~80 plain `drawLine` calls with no
/// blur, no shader, no clip and no allocation.
class SpeedField extends StatelessWidget {
  const SpeedField({
    super.key,
    required this.progress,
    required this.sign,
    required this.color,
    this.count = 26,
  });

  /// 0 → 1 clock of the beat change.
  final Animation<double> progress;

  /// +1 when the panels travel toward the right of the screen, -1 toward the
  /// left. The wind blows the same way they do.
  final double sign;

  final Color color;

  /// Streaks in the field. 26 is a full-looking field on a phone; drop it if
  /// you are running on something truly ancient.
  final int count;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _SpeedFieldPainter(
            progress: progress,
            sign: sign,
            color: color,
            streaks: _Streak.table(count),
          ),
        ),
      ),
    );
  }
}

/// One streak, entirely precomputed. Nothing here depends on the frame, so the
/// table is built once per [count] and shared forever.
class _Streak {
  /// 0..1 band down the field.
  final double y;

  /// 0 (far) .. 1 (near) — drives speed, length, weight and brightness
  /// together, which is what sells the parallax.
  final double depth;

  /// 0..1 head position along the field at t = 0, so they don't march in rank.
  final double lead;

  final double length;
  final double thick;
  final double alpha;

  /// Softens the top/bottom edges of the field so streaks don't pop against a
  /// hard band boundary. Precomputed from [y].
  final double edgeFade;

  const _Streak({
    required this.y,
    required this.depth,
    required this.lead,
    required this.length,
    required this.thick,
    required this.alpha,
    required this.edgeFade,
  });

  static final Map<int, List<_Streak>> _tables = <int, List<_Streak>>{};

  static List<_Streak> table(int count) =>
      _tables[count] ??= List<_Streak>.unmodifiable(_build(count));

  static List<_Streak> _build(int count) {
    final r = Random(0x5EED);
    return List<_Streak>.generate(count, (i) {
      final y = (i + 0.5) / count + (r.nextDouble() - 0.5) * 0.7 / count;
      final depth = r.nextDouble();
      return _Streak(
        y: y,
        depth: depth,
        lead: r.nextDouble(),
        length: 26 + depth * 130 + r.nextDouble() * 24,
        thick: 0.9 + depth * 1.8,
        alpha: 0.10 + depth * 0.42,
        // sin falloff, flat through the middle 60% of the field.
        edgeFade: pow(sin(pi * y.clamp(0.0, 1.0)), 0.55).toDouble(),
      );
    });
  }
}

class _SpeedFieldPainter extends CustomPainter {
  _SpeedFieldPainter({
    required this.progress,
    required this.sign,
    required this.color,
    required this.streaks,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final double sign;
  final Color color;
  final List<_Streak> streaks;

  /// Segments per streak — enough for a comet taper without paying for a
  /// gradient shader.
  static const _seg = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0.0 || t >= 1.0) return;

    // Speed envelope from the shared choreography: builds while the outgoing
    // panel winds up, hardest across the empty stage, gone by the lock.
    final rush = Stage(t).wind;
    if (rush < 0.03) return;
    // Squared for brightness so the flare is punchier than the stretch.
    final flare = rush * rush;

    // How far the field has been dragged. Eased the same way the panels are, so
    // wind and content agree about when the fast part is.
    final swept = Curves.easeInOutCubic.transform(t);

    final w = size.width;
    final h = size.height;
    final paint = Paint()..strokeCap = StrokeCap.round;

    for (final s in streaks) {
      // Nearer streaks cross more of the field in the same time.
      final reach = 0.55 + 0.95 * s.depth;
      final p = (s.lead + swept * reach) % 1.0;
      // Head travels with the panels; the tail trails behind it.
      final headX = sign >= 0 ? p * w : w - p * w;
      final y = s.y * h;

      final length = s.length * (0.2 + 1.8 * rush);
      final head = s.alpha * flare * s.edgeFade;
      if (head < 0.01) continue;

      for (var i = 0; i < _seg; i++) {
        final f0 = i / _seg; // 0 at the head, →1 at the tail
        final xA = headX - sign * f0 * length;
        final xB = headX - sign * (i + 1) / _seg * length;
        if ((xA < 0 && xB < 0) || (xA > w && xB > w)) continue;
        paint
          ..color = color.withValues(alpha: head * (1 - f0))
          ..strokeWidth = s.thick * (1 - 0.45 * f0);
        canvas.drawLine(Offset(xA, y), Offset(xB, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SpeedFieldPainter old) =>
      old.sign != sign || old.color != color || old.streaks != streaks;
}
