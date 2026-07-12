import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';

/// Ambient mesh-network backdrop: dim amber nodes drifting around fixed
/// anchors, with lines linking whichever pairs drift close — a nod to the
/// LAN-of-peers idea. Deliberately faint so the foreground stays the star.
/// Shared by Landing and Onboarding, which is why it lives in core.
///
/// [wave] (optional) turns the mesh into a broadcast medium: drive it 0→1
/// and a circular wavefront sweeps out from [waveOrigin] (fractional
/// coordinates), momentarily brightening every node and link it crosses —
/// one transmission rippling through the peer network. Landing passes
/// nothing and gets the original calm drift.
///
/// Owns its own [Ticker] so the page State doesn't need to drive it; the
/// ticker pauses automatically while the route is covered (TickerMode), and
/// the whole layer ignores pointer events.
class MeshBackground extends StatefulWidget {
  const MeshBackground({super.key, this.wave, this.waveOrigin});

  /// 0..1 progress of one outgoing wavefront; values outside (0, 1) draw
  /// nothing extra. An [AnimationController] fits directly.
  final ValueListenable<double>? wave;

  /// Wave epicenter in fractional screen coordinates (defaults to the upper
  /// center, roughly where Onboarding parks its emblem).
  final Offset? waveOrigin;

  @override
  State<MeshBackground> createState() => _MeshBackgroundState();
}

class _MeshBackgroundState extends State<MeshBackground>
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
            wave: widget.wave,
            waveOrigin: widget.waveOrigin ?? const Offset(0.5, 0.25),
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
  final ValueListenable<double>? wave;
  final Offset waveOrigin;

  _MeshPainter({
    required this.time,
    required this.nodes,
    required this.color,
    required this.wave,
    required this.waveOrigin,
  }) : super(repaint: wave == null ? time : Listenable.merge([time, wave]));

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    // Ease the whole layer in on first frame so it doesn't pop.
    final fade = Curves.easeOut.transform((t / 1.8).clamp(0.0, 1.0));
    if (fade == 0) return;

    final positions = [for (final n in nodes) n.positionAt(t, size)];

    // Broadcast wavefront: how close a point sits to the expanding ring
    // decides how much extra light it borrows this frame.
    final waveT = wave?.value ?? 1.0;
    final waving = waveT > 0.0 && waveT < 1.0;
    final origin = Offset(
      waveOrigin.dx * size.width,
      waveOrigin.dy * size.height,
    );
    final maxReach = _maxDistanceToCorner(origin, size);
    final front = maxReach * Curves.easeOut.transform(waveT);
    final band = size.shortestSide * 0.22;
    double boostAt(Offset p) {
      if (!waving) return 0;
      final away = ((p - origin).distance - front).abs();
      if (away >= band) return 0;
      final x = 1 - away / band;
      // Quadratic falloff inside the band, and the whole wave dims with age.
      return x * x * (1 - waveT);
    }

    // Lines: alpha grows as a pair drifts together, so links form and
    // dissolve organically instead of blinking in and out.
    final linkDistance = size.shortestSide * 0.28;
    final linePaint = Paint()..strokeWidth = 1;
    for (var i = 0; i < positions.length; i++) {
      for (var j = i + 1; j < positions.length; j++) {
        final d = (positions[i] - positions[j]).distance;
        if (d >= linkDistance) continue;
        final strength = 1 - d / linkDistance;
        final boost = (boostAt(positions[i]) + boostAt(positions[j])) / 2;
        linePaint.color = color.withAlpha(
          ((44 * strength + 130 * boost) * fade).clamp(0, 255).toInt(),
        );
        canvas.drawLine(positions[i], positions[j], linePaint);
      }
    }

    final dotPaint = Paint();
    for (var i = 0; i < nodes.length; i++) {
      final twinkle = 0.5 + 0.5 * sin(t * 1.3 + nodes[i].twinklePhase);
      final boost = boostAt(positions[i]);
      dotPaint.color = color.withAlpha(
        ((55 + 65 * twinkle + 150 * boost) * fade).clamp(0, 255).toInt(),
      );
      canvas.drawCircle(positions[i], nodes[i].radius + 1.6 * boost, dotPaint);
    }

    // The wavefront itself: a faint expanding ring so the pulse reads even
    // where no node happens to sit.
    if (waving) {
      canvas.drawCircle(
        origin,
        front,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withAlpha((36 * (1 - waveT) * fade).toInt()),
      );
    }
  }

  static double _maxDistanceToCorner(Offset origin, Size size) {
    final dx = max(origin.dx, size.width - origin.dx);
    final dy = max(origin.dy, size.height - origin.dy);
    return sqrt(dx * dx + dy * dy);
  }

  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.nodes != nodes || old.color != color || old.wave != wave;
}
