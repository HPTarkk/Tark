import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/theme/app_colors.dart';

/// Ambient mesh-network backdrop: dim amber nodes drifting around fixed
/// anchors, with lines linking whichever pairs drift close — a nod to the
/// LAN-of-peers idea. Deliberately faint so the foreground stays the star.
///
/// Owns its own [Ticker] so the page State doesn't need to drive it; the
/// ticker pauses automatically while the route is covered (TickerMode), and
/// the whole layer ignores pointer events.
class LandingMeshBackground extends StatefulWidget {
  const LandingMeshBackground({super.key});

  @override
  State<LandingMeshBackground> createState() => _LandingMeshBackgroundState();
}

class _LandingMeshBackgroundState extends State<LandingMeshBackground>
    with SingleTickerProviderStateMixin {
  static const _nodeCount = 22;

  late final Ticker _ticker;
  late final List<_MeshNode> _nodes;
  final ValueNotifier<double> _time = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    final rng = Random();
    _nodes = List.generate(_nodeCount, (_) => _MeshNode.scatter(rng));
    _ticker = createTicker(
      (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
    )..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _MeshPainter(
            time: _time,
            nodes: _nodes,
            color: AppColors.amber,
          ),
        ),
      ),
    );
  }
}

/// One node: a home position plus a slow sinusoidal orbit around it, so dots
/// wander without ever clumping or needing edge wrapping.
class _MeshNode {
  final Offset anchor; // normalized 0..1 across the available area
  final Offset amplitude; // normalized drift range around the anchor
  final double xSpeed, ySpeed; // rad/s
  final double xPhase, yPhase;
  final double radius; // px
  final double twinklePhase;

  const _MeshNode({
    required this.anchor,
    required this.amplitude,
    required this.xSpeed,
    required this.ySpeed,
    required this.xPhase,
    required this.yPhase,
    required this.radius,
    required this.twinklePhase,
  });

  factory _MeshNode.scatter(Random rng) => _MeshNode(
    anchor: Offset(rng.nextDouble(), rng.nextDouble()),
    amplitude: Offset(
      0.03 + rng.nextDouble() * 0.05,
      0.03 + rng.nextDouble() * 0.05,
    ),
    xSpeed: 0.15 + rng.nextDouble() * 0.25,
    ySpeed: 0.15 + rng.nextDouble() * 0.25,
    xPhase: rng.nextDouble() * 2 * pi,
    yPhase: rng.nextDouble() * 2 * pi,
    radius: 1.2 + rng.nextDouble() * 1.3,
    twinklePhase: rng.nextDouble() * 2 * pi,
  );

  Offset positionAt(double t, Size size) => Offset(
    (anchor.dx + amplitude.dx * sin(xSpeed * t + xPhase)) * size.width,
    (anchor.dy + amplitude.dy * cos(ySpeed * t + yPhase)) * size.height,
  );
}

// ── Mesh painter ──────────────────────────────────────────────────────────────

class _MeshPainter extends CustomPainter {
  final ValueListenable<double> time;
  final List<_MeshNode> nodes;
  final Color color;

  _MeshPainter({required this.time, required this.nodes, required this.color})
    : super(repaint: time);

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    // Ease the whole layer in on first frame so it doesn't pop.
    final fade = Curves.easeOut.transform((t / 1.8).clamp(0.0, 1.0));
    if (fade == 0) return;

    final positions = [for (final n in nodes) n.positionAt(t, size)];

    // Lines: alpha grows as a pair drifts together, so links form and
    // dissolve organically instead of blinking in and out.
    final linkDistance = size.shortestSide * 0.28;
    final linePaint = Paint()..strokeWidth = 1;
    for (var i = 0; i < positions.length; i++) {
      for (var j = i + 1; j < positions.length; j++) {
        final d = (positions[i] - positions[j]).distance;
        if (d >= linkDistance) continue;
        final strength = 1 - d / linkDistance;
        linePaint.color = color.withAlpha((44 * strength * fade).toInt());
        canvas.drawLine(positions[i], positions[j], linePaint);
      }
    }

    final dotPaint = Paint();
    for (var i = 0; i < nodes.length; i++) {
      final twinkle = 0.5 + 0.5 * sin(t * 1.3 + nodes[i].twinklePhase);
      dotPaint.color = color.withAlpha(((55 + 65 * twinkle) * fade).toInt());
      canvas.drawCircle(positions[i], nodes[i].radius, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.nodes != nodes || old.color != color;
}
