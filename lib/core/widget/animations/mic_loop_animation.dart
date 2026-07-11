// mic_loop_animation.dart
//
// Seamless looping mic animation — hands-free mic, wide-open sensitivity,
// noise suppression — recreated in Flutter from the web (HTML/CSS) version.
// Pure visual metaphor, no text. Drop this file into a Flutter project's
// lib/ folder (or paste MicLoopAnimation into an existing app) and run.
//

import 'dart:math' as math;
import 'package:flutter/material.dart';

// ── Palette ──────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFF5853F);
final Color kAccentSoft = kAccent.withValues(alpha: 0.35);
final Color kAccentFaint = kAccent.withValues(alpha: 0.14);
final Color kSpeck = const Color(0xFFFFD4B8).withValues(alpha: 0.85);

const double kDurationSeconds = 4.5;
const double kCanvasSize = 800;


class MicLoopAnimation extends StatefulWidget {
  const MicLoopAnimation({super.key});

  @override
  State<MicLoopAnimation> createState() => _MicLoopAnimationState();
}

class _MicLoopAnimationState extends State<MicLoopAnimation> with SingleTickerProviderStateMixin {
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
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _MicLoopPainter(phase: _controller.value),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _BarSpec {
  final double freq;
  final double off;
  const _BarSpec(this.freq, this.off);
}

class _MicLoopPainter extends CustomPainter {
  final double phase; // 0..1, wraps seamlessly

  _MicLoopPainter({required this.phase});

  static const List<_BarSpec> _bars = [
    _BarSpec(3, 0.0),
    _BarSpec(4, 0.15),
    _BarSpec(2, 0.3),
    _BarSpec(5, 0.5),
    _BarSpec(2, 0.68),
    _BarSpec(4, 0.82),
    _BarSpec(3, 0.92),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Draw everything in an 800x800 logical space, then scale to fit.
    final double scale = size.width / kCanvasSize;
    canvas.save();
    canvas.scale(scale, scale);

    final double cx = kCanvasSize / 2;
    final double cy = kCanvasSize / 2 + 10;
    final double p = phase;
    final double twoPi = 2 * math.pi;

    // Mic breathes gently — always listening, nothing to press.
    final double micScale = 1 + 0.028 * math.sin(twoPi * p * 2);

    // Ambient glow, slow breathing halo.
    final double glowOpacity = 0.35 + 0.12 * math.sin(twoPi * p * 2 + math.pi / 2);
    final double glowRadius = 190 + 14 * math.sin(twoPi * p * 2);
    // final Paint glowPaint = Paint()
    //   ..shader = RadialGradient(
    //     colors: [kAccentFaint, kAccent.withValues(alpha: 0)],
    //   ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: glowRadius))
    //   ..color = Colors.white.withValues(alpha: glowOpacity.clamp(0, 1));
    // Apply opacity via saveLayer so the gradient's own alpha is scaled too.
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

    // Sensitivity rings — "wide open" zone, breathing outward/inward.
    _ring(
      canvas,
      cx,
      cy,
      290 + 20 * math.sin(twoPi * p * 2 + 1.2),
      0.14 + 0.06 * math.sin(twoPi * p * 2 + 1.2),
      1.0,
    );
    _ring(
      canvas,
      cx,
      cy,
      220 + 16 * math.sin(twoPi * p * 2 + 0.6),
      0.28 + 0.1 * math.sin(twoPi * p * 2 + 0.6),
      1.25,
    );
    _ring(canvas, cx, cy, 150 + 10 * math.sin(twoPi * p * 2), 0.5 + 0.15 * math.sin(twoPi * p * 2), 1.5);

    // Noise specks — drift in from the wide sensitivity zone and dissolve
    // before reaching the mic: noise suppression doing the work.
    for (int i = 0; i < 9; i++) {
      final double localPhase = (p + i / 9) % 1.0;
      const double outerR = 300;
      const double innerR = 130;
      final double radius = outerR - (outerR - innerR) * localPhase;
      final double opacity = math.sin(math.pi * localPhase) * 0.8;
      final double angleDeg = i * 40 + p * 30;
      final double angleRad = angleDeg * math.pi / 180;
      final double dotSize = 5 + 3 * math.sin(math.pi * localPhase);
      final double dx = cx + radius * math.cos(angleRad);
      final double dy = cy + radius * math.sin(angleRad) * 0.92;
      final Paint speckPaint = Paint()
        ..color = kSpeck.withValues(alpha: (kSpeck.a * opacity).clamp(0, 1))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      canvas.drawCircle(Offset(dx, dy), dotSize / 2, speckPaint);
    }

    // Mic icon.
    _drawMic(canvas, cx, cy - 20, micScale);

    // Waveform bars — continuous ambient signal beneath the mic.
    const double barGap = 24;
    final double barsStartX = cx - ((_bars.length - 1) * barGap) / 2;
    final double barsCenterY = cy + 118;
    final Paint barPaint = Paint()..color = kAccent;
    for (int i = 0; i < _bars.length; i++) {
      final b = _bars[i];
      final double s = (twoPi * (p * b.freq + b.off));
      final double h = 14 + 34 * math.sin(s).abs();
      final double o = 0.55 + 0.35 * math.sin(s).abs();
      final double x = barsStartX + i * barGap;
      final RRect bar = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, barsCenterY), width: 10, height: h),
        const Radius.circular(5),
      );
      canvas.drawRRect(bar, barPaint..color = kAccent.withValues(alpha: o));
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

  void _drawMic(Canvas canvas, double originX, double originY, double scale) {
    canvas.save();
    canvas.translate(originX, originY);
    canvas.scale(scale);
    // Local coordinates are shifted so (0,0) sits at the icon's visual center
    // (matches the original 200x260 viewBox, centered near (100,115)).
    final Paint fill = Paint()..color = kAccent;
    final Paint stroke = Paint()
      ..color = kAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Headband.
    final Rect bandRect = Rect.fromCircle(center: const Offset(0, -25), radius: 68);
    final Path bandPath = Path()..addArc(bandRect, math.pi, math.pi);
    canvas.drawPath(bandPath, stroke..strokeWidth = 10);

    // Earcups.
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(-86, -33, 36, 72), const Radius.circular(18)),
      fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(50, -33, 36, 72), const Radius.circular(18)),
      fill,
    );

    // Boom arm to mouth-level mic.
    final Path boom = Path()
      ..moveTo(58, 35)
      ..cubicTo(50, 75, 20, 90, 0, 93);
    canvas.drawPath(boom, stroke..strokeWidth = 8);

    // Mic capsule at boom tip.
    canvas.drawCircle(const Offset(0, 95), 9, fill);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MicLoopPainter oldDelegate) => oldDelegate.phase != phase;
}
