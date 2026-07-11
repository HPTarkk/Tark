// helmet_loop_animation_light.dart
//
// Seamless looping "always wear a proper helmet" animation — recreated in
// Flutter from the web (HTML/CSS) version. Uses the same motorcycle-helmet
// artwork (recolored to the amber/navy palette) with a breathing protection
// aura, hazard specks dissolving before they reach it, and pulsing
// clear-audio sound waves at ear height, curving in toward the helmet.
//


import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../gen/assets.gen.dart';

// ── Palette ──────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFB26B00);
final Color kAccentSoft = kAccent.withValues(alpha: 0.35);
final Color kAccentFaint = kAccent.withValues(alpha: 0.14);
final Color kHazard = const Color(0xFF7A4600).withValues(alpha: 0.6);

const double kDurationSeconds = 4.5;
const double kCanvasSize = 800;

// Icon box (same layout math as the web version): centered horizontally,
// shifted up slightly.
const double kIconW = 200;
const double kIconH = 260;
const double kIconLeft = kCanvasSize / 2 - kIconW / 2; // 300
const double kIconTop = kCanvasSize / 2 + 10 - 0.55 * kIconH; // 267

/// Square, seamlessly-looping helmet safety animation.
class HelmetLoopAnimationLight extends StatefulWidget {
  const HelmetLoopAnimationLight({super.key});

  @override
  State<HelmetLoopAnimationLight> createState() => _HelmetLoopAnimationLightState();
}

class _HelmetLoopAnimationLightState extends State<HelmetLoopAnimationLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (kDurationSeconds * 1000).round()),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: kCanvasSize,
          height: kCanvasSize,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final double phase = _controller.value;
              final double twoPi = 2 * math.pi;
              final double helmetScale = 1 + 0.022 * math.sin(twoPi * phase * 2);
              final double waveOpacity = 0.55 + 0.35 * math.sin(twoPi * phase * 3).abs();
              final double waveScale = 0.9 + 0.14 * math.sin(twoPi * phase * 3).abs();

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  CustomPaint(
                    size: const Size(kCanvasSize, kCanvasSize),
                    painter: _BackdropPainterLight(phase: phase),
                  ),
                  Positioned(
                    left: kIconLeft,
                    top: kIconTop,
                    width: kIconW,
                    height: kIconH,
                    child: Transform.scale(
                      scale: helmetScale,
                      child: Image.asset(
                        Assets.image.helmetLight.path,
                        width: kIconW,
                        height: kIconH,
                        fit: BoxFit.fill,
                      ),
                    ),
                  ),
                  CustomPaint(
                    size: const Size(kCanvasSize, kCanvasSize),
                    painter: _WavesPainterLight(waveOpacity: waveOpacity, waveScale: waveScale),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Background: navy fill, ambient glow, breathing protection rings, and
/// hazard specks that drift in and dissolve before reaching the helmet.
class _BackdropPainterLight extends CustomPainter {
  final double phase; // 0..1, wraps seamlessly
  _BackdropPainterLight({required this.phase});

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / kCanvasSize;
    canvas.save();
    canvas.scale(scale, scale);

    final double cx = kCanvasSize / 2;
    final double cy = kCanvasSize / 2 + 10;
    final double p = phase;
    final double twoPi = 2 * math.pi;

    // Ambient glow.
    final double glowOpacity = 0.35 + 0.12 * math.sin(twoPi * p * 2 + math.pi / 2);
    final double glowRadius = 190 + 14 * math.sin(twoPi * p * 2);
    canvas.saveLayer(
      Rect.fromCircle(center: Offset(cx, cy), radius: glowRadius),
      Paint()..color = Colors.white.withValues(alpha: glowOpacity.clamp(0, 1)),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      glowRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [kAccentFaint, kAccent.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: glowRadius)),
    );
    canvas.restore();

    // Protection rings — the "safety first" aura, breathing.
    _ring(
      canvas,
      cx,
      cy,
      300 + 20 * math.sin(twoPi * p * 2 + 1.2),
      0.14 + 0.06 * math.sin(twoPi * p * 2 + 1.2),
      1.0,
    );
    _ring(
      canvas,
      cx,
      cy,
      230 + 16 * math.sin(twoPi * p * 2 + 0.6),
      0.28 + 0.1 * math.sin(twoPi * p * 2 + 0.6),
      1.25,
    );
    _ring(canvas, cx, cy, 160 + 10 * math.sin(twoPi * p * 2), 0.5 + 0.15 * math.sin(twoPi * p * 2), 1.5);

    // Hazard specks — dissolve at the protection boundary.
    for (int i = 0; i < 9; i++) {
      final double localPhase = (p + i / 9) % 1.0;
      const double outerR = 310;
      const double innerR = 165;
      final double radius = outerR - (outerR - innerR) * localPhase;
      final double opacity = math.sin(math.pi * localPhase) * 0.8;
      final double angleDeg = i * 40 + p * 30;
      final double angleRad = angleDeg * math.pi / 180;
      final double dotSize = 5 + 3 * math.sin(math.pi * localPhase);
      final double dx = cx + radius * math.cos(angleRad);
      final double dy = cy + radius * math.sin(angleRad) * 0.92;
      final Paint speckPaint = Paint()..color = kHazard.withValues(alpha: (kHazard.a * opacity).clamp(0, 1));
      canvas.drawCircle(Offset(dx, dy), dotSize / 2, speckPaint);
    }

    canvas.restore();
  }

  void _ring(Canvas canvas, double cx, double cy, double radius, double opacity, double strokeWidth) {
    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = kAccent.withValues(alpha: opacity.clamp(0, 1));
    canvas.drawCircle(Offset(cx, cy), radius, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _BackdropPainterLight oldDelegate) => oldDelegate.phase != phase;
}

/// Foreground: clear-audio sound waves at ear height, curving in toward
/// the helmet on both sides.
class _WavesPainterLight extends CustomPainter {
  final double waveOpacity;
  final double waveScale;
  _WavesPainterLight({required this.waveOpacity, required this.waveScale});

  static const double _earY = kIconTop + 0.44 * kIconH;
  static const double _leftEarX = kIconLeft - 18;
  static const double _rightEarX = kIconLeft + kIconW + 18;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / kCanvasSize;
    canvas.save();
    canvas.scale(scale, scale);

    final Paint p1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = kAccent.withValues(alpha: waveOpacity.clamp(0, 1));
    final Paint p2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = kAccent.withValues(alpha: (waveOpacity * 0.7).clamp(0, 1));
    final Paint p3 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = kAccent.withValues(alpha: (waveOpacity * 0.4).clamp(0, 1));

    _wavesAt(canvas, _leftEarX, _earY, -waveScale, p1, p2, p3);
    _wavesAt(canvas, _rightEarX, _earY, waveScale, p1, p2, p3);

    canvas.restore();
  }

  // Arcs curve inward (toward the helmet) — mirrored via sx sign.
  void _wavesAt(Canvas canvas, double x, double y, double sx, Paint p1, Paint p2, Paint p3) {
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(sx, waveScale);
    _arc(canvas, 18, p1);
    _arc(canvas, 30, p2);
    _arc(canvas, 42, p3);
    canvas.restore();
  }

  void _arc(Canvas canvas, double r, Paint paint) {
    // Matches SVG "M0 -r A r r 0 0 1 0 r" — a semicircle bulging toward +x.
    final Rect rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final Path path = Path()..addArc(rect, -math.pi / 2, math.pi);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavesPainterLight oldDelegate) =>
      oldDelegate.waveOpacity != waveOpacity || oldDelegate.waveScale != waveScale;
}
