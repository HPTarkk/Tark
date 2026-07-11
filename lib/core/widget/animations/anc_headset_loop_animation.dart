// anc_headset_loop_animation.dart
//
// Seamless looping "pair an ANC / hands-free headset" animation — recreated
// in Flutter from the web (HTML/CSS) version. Uses the AirPods artwork
// (split into case + a single floating earbud, recolored to the amber/navy
// palette) with a breathing case, a bobbing earbud, pulsing clear-channel
// audio waves at the earbud, and jagged wind/engine noise squiggles that
// flatten out and dissolve before they reach it (active noise cancellation).
//
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:tark/gen/assets.gen.dart';

// ── Palette ──────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFF5853F);
final Color kAccentSoft = kAccent.withValues(alpha: 0.35);
final Color kAccentFaint = kAccent.withValues(alpha: 0.14);

const double kDurationSeconds = 4.5;
const double kCanvasSize = 800;

// Icon box (same layout math as the web version).
const double kIconW = 280;
const double kIconH = 244;
const double kIconLeft = kCanvasSize / 2 - kIconW / 2;
const double kIconTop = kCanvasSize / 2 + 10 - 0.55 * kIconH;

// Earbud position within the icon box (where the loose bud sits).
const double kEarX = 0.86 * kIconW;
const double kEarY = 0.82 * kIconH;

/// Square, seamlessly-looping AirPods pairing / ANC animation.
class AncHeadsetLoopAnimation extends StatefulWidget {
  const AncHeadsetLoopAnimation({super.key});

  @override
  State<AncHeadsetLoopAnimation> createState() => _AncHeadsetLoopAnimationState();
}

class _AncHeadsetLoopAnimationState extends State<AncHeadsetLoopAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration:  Duration(milliseconds: (kDurationSeconds * 1000).round()),
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
              final double caseScale = 1 + 0.022 * math.sin(twoPi * phase * 2);
              final double bobY = math.sin(twoPi * phase * 2) * 6;
              final double bobRotDeg = math.sin(twoPi * phase * 2 + 0.5) * 3;
              final double waveOpacity = 0.55 + 0.35 * math.sin(twoPi * phase * 3).abs();
              final double waveScale = 0.9 + 0.14 * math.sin(twoPi * phase * 3).abs();

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  CustomPaint(
                    size: const Size(kCanvasSize, kCanvasSize),
                    painter: _BackdropPainter(phase: phase),
                  ),
                  // Case, breathing gently.
                  Positioned(
                    left: kIconLeft,
                    top: kIconTop,
                    width: kIconW,
                    height: kIconH,
                    child: Transform.scale(
                      scale: caseScale,
                      child: Image.asset(Assets.image.airpodsCase.path, width: kIconW, height: kIconH),
                    ),
                  ),
                  // Single earbud, bobbing beside the case.
                  Positioned(
                    left: kIconLeft,
                    top: kIconTop,
                    width: kIconW,
                    height: kIconH,
                    child: Transform.scale(
                      scale: caseScale,
                      child: Transform.translate(
                        offset: Offset(0, bobY),
                        child: Transform.rotate(
                          angle: bobRotDeg * math.pi / 180,
                          alignment: Alignment(
                            (kEarX / kIconW) * 2 - 1,
                            (kEarY / kIconH) * 2 - 1,
                          ),
                          child: Image.asset(Assets.image.airpodBud.path, width: kIconW, height: kIconH),
                        ),
                      ),
                    ),
                  ),
                  // Clear-channel audio pulsing at the earbud.
                  CustomPaint(
                    size: const Size(kCanvasSize, kCanvasSize),
                    painter: _WavePainter(waveOpacity: waveOpacity, waveScale: waveScale),
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

/// Background: navy fill, ambient glow, breathing ANC-boundary rings, and
/// jagged wind/engine noise squiggles that flatten and dissolve before they
/// reach the earbud.
class _BackdropPainter extends CustomPainter {
  final double phase; // 0..1, wraps seamlessly
  _BackdropPainter({required this.phase});

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
        ..shader = RadialGradient(colors: [kAccentFaint, kAccent.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: Offset(cx, cy), radius: glowRadius)),
    );
    canvas.restore();

    // ANC boundary rings, breathing.
    _ring(canvas, cx, cy, 300 + 20 * math.sin(twoPi * p * 2 + 1.2),
        0.14 + 0.06 * math.sin(twoPi * p * 2 + 1.2), 1.0);
    _ring(canvas, cx, cy, 230 + 16 * math.sin(twoPi * p * 2 + 0.6),
        0.28 + 0.1 * math.sin(twoPi * p * 2 + 0.6), 1.25);
    _ring(canvas, cx, cy, 160 + 10 * math.sin(twoPi * p * 2),
        0.5 + 0.15 * math.sin(twoPi * p * 2), 1.5);

    // Wind / engine noise squiggles, cancelled before they arrive.
    for (int i = 0; i < 7; i++) {
      final double localPhase = (p + i / 7) % 1.0;
      const double outerR = 310;
      const double innerR = 175;
      final double radius = outerR - (outerR - innerR) * localPhase;
      final double opacity = math.sin(math.pi * localPhase) * 0.85;
      final double ampScale = math.max(0.06, 1 - localPhase * 1.05);
      final double angleDeg = i * 51 + p * 22;
      final double angleRad = angleDeg * math.pi / 180;
      final double sizeScale = 0.75 + 0.35 * (1 - localPhase);
      final double dx = cx + radius * math.cos(angleRad);
      final double dy = cy + radius * math.sin(angleRad) * 0.92;
      _drawSquiggle(canvas, dx, dy, ampScale, sizeScale, opacity);
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

  void _drawSquiggle(Canvas canvas, double x, double y, double ampScale, double sizeScale, double opacity) {
    final double a = 9 * ampScale;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = kAccent.withValues(alpha: opacity.clamp(0, 1));
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(sizeScale);
    final Path path = Path()
      ..moveTo(-12, 0)
      ..lineTo(-6, -a)
      ..lineTo(0, a)
      ..lineTo(6, -a)
      ..lineTo(12, 0);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter oldDelegate) => oldDelegate.phase != phase;
}

/// Foreground: clear-channel audio pulsing from the earbud only.
class _WavePainter extends CustomPainter {
  final double waveOpacity;
  final double waveScale;
  _WavePainter({required this.waveOpacity, required this.waveScale});

  static const double _earGlobalX = kIconLeft + kEarX + 40;
  static const double _earGlobalY = kIconTop + kEarY;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / kCanvasSize;
    canvas.save();
    canvas.scale(scale, scale);

    final Paint p1 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = kAccent.withValues(alpha: waveOpacity.clamp(0, 1));
    final Paint p2 = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = kAccent.withValues(alpha: (waveOpacity * 0.7).clamp(0, 1));

    canvas.save();
    canvas.translate(_earGlobalX, _earGlobalY);
    canvas.scale(waveScale);
    _arc(canvas, 15, p1);
    _arc(canvas, 25, p2);
    canvas.restore();

    canvas.restore();
  }

  void _arc(Canvas canvas, double r, Paint paint) {
    final Rect rect = Rect.fromCircle(center: Offset.zero, radius: r);
    final Path path = Path()..addArc(rect, -math.pi / 2, math.pi);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) =>
      oldDelegate.waveOpacity != waveOpacity || oldDelegate.waveScale != waveScale;
}
