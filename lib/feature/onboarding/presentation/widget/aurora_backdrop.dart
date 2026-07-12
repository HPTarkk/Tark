import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Slow warm aurora behind the mesh: three large soft-gradient blobs
/// drifting on independent orbits, far dimmer than the splash version so
/// the beat content stays the star — this layer only keeps the air moving.
class AuroraBackdrop extends StatelessWidget {
  /// 0..1 slow ambient loop (shared with the emblem's halo spin).
  final Animation<double> drift;

  /// 0..1 breathing loop modulating the warmest blob.
  final Animation<double> breath;

  const AuroraBackdrop({super.key, required this.drift, required this.breath});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([drift, breath]),
          builder: (_, _) => CustomPaint(
            size: Size.infinite,
            painter: _AuroraPainter(
              drift: drift.value,
              breath: breath.value,
              amber: AppColors.amber,
              amberDim: AppColors.amberDim,
              haze: AppColors.border,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double drift;
  final double breath;
  final Color amber;
  final Color amberDim;
  final Color haze;

  const _AuroraPainter({
    required this.drift,
    required this.breath,
    required this.amber,
    required this.amberDim,
    required this.haze,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final d = 2 * pi * drift;
    _blob(
      canvas,
      size,
      Offset(0.20 + 0.06 * sin(d), 0.16 + 0.05 * cos(d * 0.8)),
      0.52,
      amber,
      (10 + 6 * breath).toInt(),
    );
    _blob(
      canvas,
      size,
      Offset(0.85 - 0.07 * cos(d * 0.7), 0.72 + 0.06 * sin(d * 0.9)),
      0.48,
      amberDim,
      9,
    );
    _blob(
      canvas,
      size,
      Offset(0.70 + 0.05 * sin(d * 0.6 + 1), 0.36 + 0.05 * cos(d * 0.5)),
      0.42,
      haze,
      60,
    );
  }

  void _blob(
    Canvas canvas,
    Size size,
    Offset unitCenter,
    double unitRadius,
    Color color,
    int alpha,
  ) {
    if (alpha <= 0) return;
    final center = Offset(
      unitCenter.dx * size.width,
      unitCenter.dy * size.height,
    );
    final radius = unitRadius * size.longestSide;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withAlpha(alpha), color.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.drift != drift || old.breath != breath || old.amber != amber;
}
