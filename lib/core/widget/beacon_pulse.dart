import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';

/// The app's small "working on it" mark: a beacon sending out rings.
///
/// Used wherever a button, a chip or a status line is waiting on the phone —
/// the places a stock circular spinner used to sit, each with its own stroke
/// and colour. A spinner says *wait*; this is the same signal every
/// connection scene in the app is drawn with (the invite beacon, the journey
/// between two phones), so a small wait reads as part of that one thing
/// instead of a piece of the platform showing through.
///
/// One controller, one painter, two strokes and a dot: cheap enough to sit
/// inside a list row. Under reduced motion nothing moves — a still dot with
/// one ring, which is still unmistakably "in progress" beside the label that
/// always accompanies it.
class BeaconPulse extends StatefulWidget {
  const BeaconPulse({
    this.size = 20,
    this.color,
    this.inheritColor = false,
    super.key,
  });

  /// The square it occupies.
  final double size;

  /// Defaults to the accent.
  final Color? color;

  /// Takes the surrounding icon colour instead, for a button's icon slot:
  /// the button already knows its own ink, enabled or not.
  final bool inheritColor;

  /// One ring's life, centre to edge.
  static const period = Duration(milliseconds: 1500);

  @override
  State<BeaconPulse> createState() => _BeaconPulseState();
}

class _BeaconPulseState extends State<BeaconPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: BeaconPulse.period,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clock.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _BeaconPulsePainter(
          clock: _clock,
          color:
              widget.color ??
              (widget.inheritColor ? IconTheme.of(context).color : null) ??
              AppColors.amber,
          still: AppMotion.reduced(context),
        ),
      ),
    ),
  );
}

class _BeaconPulsePainter extends CustomPainter {
  _BeaconPulsePainter({
    required this.clock,
    required this.color,
    required this.still,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final Color color;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final extent = size.shortestSide / 2;
    final stroke = math.max(1.3, extent * 0.12);
    final core = math.max(1.6, extent * 0.26);
    final reach = extent - stroke / 2;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    if (still) {
      ring.color = color.withValues(alpha: 0.45);
      canvas.drawCircle(centre, core + (reach - core) * 0.62, ring);
    } else {
      // Two rings half a period apart, so one is always leaving as the
      // other is born and the mark never blinks empty.
      for (final offset in const [0.0, 0.5]) {
        final t = (clock.value + offset) % 1.0;
        final eased = Curves.easeOutCubic.transform(t);
        ring.color = color.withValues(alpha: 0.9 * (1 - t) * (1 - t));
        canvas.drawCircle(centre, core + (reach - core) * eased, ring);
      }
    }
    // The beacon itself breathes very slightly with each ring it sends.
    final breath = still
        ? 1.0
        : 1 + 0.12 * math.sin(clock.value * 2 * math.pi * 2);
    canvas.drawCircle(centre, core * breath, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BeaconPulsePainter old) =>
      old.color != color || old.still != still;
}
