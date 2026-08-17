import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// The joiner's two live states, drawn rather than spun.
///
/// Both replace stock Material widgets that were the only things on this
/// journey not speaking the app's language: a `CircularProgressIndicator` for
/// the association, and a static bordered note for having arrived. Either side
/// of them the user is looking at a radar sweep, a beacon pulse and the
/// link-established sequence, so a generic spinner read as an unfinished
/// screen.
///
/// They are deliberately different in temperature. Joining is **amber and
/// impatient** — a wave reaching outward, repeating, clearly mid-effort.
/// Joined is **green and calm** — a settled node breathing slowly, because
/// being on the host's network is not the finish line: the peer still has to
/// show up, and the real celebration belongs to `LinkEstablished` when the
/// channel opens. Making this one triumphant would spend that moment twice.
///
/// Both are one painter driven by one controller, built from arcs and circles
/// with no blur, shader or clip — the low-end 60 fps floor (Mali-G71) is the
/// constraint, and these run while Wi-Fi association is already competing for
/// the CPU.

/// Reaching for the host's network: three arcs pulsing outward from a node.
class HotspotReachPulse extends StatefulWidget {
  const HotspotReachPulse({super.key, this.size = 84});

  final double size;

  @override
  State<HotspotReachPulse> createState() => _HotspotReachPulseState();
}

class _HotspotReachPulseState extends State<HotspotReachPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _ReachPainter(t: _c.value, color: AppColors.amber),
          ),
        ),
      ),
    );
  }
}

/// The Wi-Fi arc stack, lit as a wave travelling away from the device.
///
/// Drawn from the bottom centre outward, which is the one orientation everyone
/// already reads as signal strength — the familiarity is the point, since this
/// has to be legible at a glance to someone holding a phone at arm's length.
class _ReachPainter extends CustomPainter {
  _ReachPainter({required this.t, required this.color});

  final double t;
  final Color color;

  static const _arcs = 3;

  @override
  void paint(Canvas canvas, Size size) {
    // Sits low in the box so the arcs have room to travel upward.
    final origin = Offset(size.width / 2, size.height * 0.80);

    canvas.drawCircle(origin, 3.5, Paint()..color = color);

    for (var i = 0; i < _arcs; i++) {
      // Each arc lags the one inside it, so the wave visibly leaves the node
      // rather than the whole stack blinking together.
      final phase = (t - i * 0.17) % 1.0;
      // Lit for the first 55 %, dark for the rest: the gap is what makes it a
      // pulse instead of a shimmer.
      final lit = phase < 0.55 ? math.sin(math.pi * (phase / 0.55)) : 0.0;
      if (lit <= 0.01) continue;

      final radius = size.width * (0.17 + i * 0.15);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: radius),
        math.pi * 1.25,
        math.pi * 0.5,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 0.22 + 0.68 * lit),
      );
    }
  }

  @override
  bool shouldRepaint(_ReachPainter old) => old.t != t || old.color != color;
}

/// On the host's network, listening for the other phone.
///
/// A held node with slow rings leaving it — the same "we are transmitting and
/// nobody has answered yet" idea as the host's waiting pulse, so both sides of
/// the bridge look like they are doing the same thing while they wait.
class HotspotJoinedPulse extends StatefulWidget {
  const HotspotJoinedPulse({super.key, this.size = 72});

  final double size;

  @override
  State<HotspotJoinedPulse> createState() => _HotspotJoinedPulseState();
}

class _HotspotJoinedPulseState extends State<HotspotJoinedPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    // Slow on purpose. This is a waiting state that can be on screen for a
    // minute, and anything brisker starts to read as urgency.
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(
            painter: _ListenPainter(t: _c.value, color: AppColors.green),
          ),
        ),
      ),
    );
  }
}

class _ListenPainter extends CustomPainter {
  _ListenPainter({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.shortestSide / 2;

    // Three rings, evenly spaced through the cycle, so one leaves roughly
    // every 870 ms and the node is never sitting still.
    //
    // Weights tuned against a render rather than by eye in code: the first
    // pass used 1.6 px at 45 % opacity, which was invisible at the 84 px this
    // is actually drawn at — a "pulse" nobody could see is just a static icon
    // that cost an AnimationController.
    for (final offset in [0.0, 0.33, 0.66]) {
      final p = (t + offset) % 1.0;
      final eased = Curves.easeOut.transform(p);
      canvas.drawCircle(
        center,
        maxR * (0.36 + eased * 0.64),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4 * (1 - eased * 0.75)
          ..color = color.withValues(alpha: 0.7 * (1 - eased)),
      );
    }

    final r = maxR * 0.32;
    canvas.drawCircle(
      center,
      r,
      Paint()..color = color.withValues(alpha: 0.16),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    // A tick, because the network part genuinely is done — small, inside the
    // node, not the headline.
    final u = r * 0.52;
    canvas.drawPath(
      Path()
        ..moveTo(center.dx - u * 0.8, center.dy)
        ..lineTo(center.dx - u * 0.2, center.dy + u * 0.6)
        ..lineTo(center.dx + u * 0.85, center.dy - u * 0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_ListenPainter old) => old.t != t || old.color != color;
}
