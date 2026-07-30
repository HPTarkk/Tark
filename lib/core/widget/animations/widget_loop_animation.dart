// widget_loop_animation.dart
//
// Seamless looping home-screen-widget animation — the Tark dial sitting on a
// phone's home screen, alive: gauge swinging, level bars bouncing, signal
// radiating. Pure visual metaphor, no text.
//
// Deliberately built from flat shapes only — rounded rects, circles, arcs,
// lines. No MaskFilter blurs, no per-frame ClipPath or shader construction:
// this has to hold 60fps on a Galaxy S8-class device, and those are the three
// things that reliably break that budget.

import 'dart:math' as math;
import 'package:flutter/material.dart';

// ── Palette ──────────────────────────────────────────────────────────────
const Color kAccent = Color(0xFFF5853F);
const Color kPhoneFill = Color(0xFF0B0E11);
const Color kPhoneEdge = Color(0xFF2D343D);
const Color kCardFill = Color(0xFF1A2027);
const Color kCardEdge = Color(0xFF3E4753);
const Color kIcon = Color(0xFF232A33);
const Color kDim = Color(0xFF8B939D);

const double kDurationSeconds = 4.0;
const double kCanvasSize = 800;

class WidgetLoopAnimation extends StatefulWidget {
  const WidgetLoopAnimation({super.key});

  @override
  State<WidgetLoopAnimation> createState() => _WidgetLoopAnimationState();
}

class _WidgetLoopAnimationState extends State<WidgetLoopAnimation>
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
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: WidgetLoopPainter(phase: _controller.value),
          size: Size.infinite,
        ),
      ),
    );
  }
}

/// Shared by the dark and light variants — only the colors differ, so the
/// geometry lives in one place rather than being copy-edited twice.
class WidgetLoopPainter extends CustomPainter {
  /// 0..1, wraps seamlessly. Every animated quantity below is built from
  /// `sin`/`cos` of a whole multiple of this, or from its fractional part, so
  /// the last frame lines up with the first and the loop has no visible seam.
  final double phase;

  final Color accent;
  final Color phoneFill;
  final Color phoneEdge;
  final Color cardFill;
  final Color cardEdge;
  final Color icon;
  final Color dim;

  WidgetLoopPainter({
    required this.phase,
    this.accent = kAccent,
    this.phoneFill = kPhoneFill,
    this.phoneEdge = kPhoneEdge,
    this.cardFill = kCardFill,
    this.cardEdge = kCardEdge,
    this.icon = kIcon,
    this.dim = kDim,
  });

  // The phone is framed large and runs off the bottom of the canvas: this
  // tip is about the WIDGET, so the widget is the hero and the phone is just
  // enough context to read as a home screen. An earlier pass drew the whole
  // phone to scale, which left the card too small to make out at the ~200px
  // this renders at inside the tips sheet.
  static const _dialCenter = Offset(302, 250);
  static const _dialRadius = 74.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Everything is authored in an 800x800 logical space, then scaled to fit.
    final scale = size.width / kCanvasSize;
    canvas.save();
    canvas.scale(scale, scale);

    _drawPhone(canvas);
    _drawAppIcons(canvas);
    _drawCard(canvas);
    _drawPulses(canvas);
    _drawDial(canvas);
    _drawCardText(canvas);

    canvas.restore();
  }

  void _drawPhone(Canvas canvas) {
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(170, 50, 460, 900),
      const Radius.circular(72),
    );
    canvas.drawRRect(body, Paint()..color = phoneFill);
    canvas.drawRRect(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = phoneEdge,
    );
    // Speaker slot.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(368, 86, 64, 13),
        const Radius.circular(7),
      ),
      Paint()..color = phoneEdge,
    );
  }

  /// Static grid of app tiles, so the widget reads as sitting on a real home
  /// screen rather than floating on its own.
  void _drawAppIcons(Canvas canvas) {
    final paint = Paint()..color = icon;
    const startX = 208.0;
    const stepX = 100.0;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 4; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(startX + col * stepX, 400 + row * 120, 76, 76),
            const Radius.circular(24),
          ),
          paint,
        );
      }
    }
    // Dock.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(194, 762, 412, 130),
        const Radius.circular(42),
      ),
      Paint()..color = icon.withValues(alpha: 0.55),
    );
  }

  void _drawCard(Canvas canvas) {
    final card = RRect.fromRectAndRadius(
      const Rect.fromLTWH(206, 150, 388, 200),
      const Radius.circular(42),
    );
    canvas.drawRRect(card, Paint()..color = cardFill);
    canvas.drawRRect(
      card,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = cardEdge,
    );
  }

  /// Two rings radiating from the dial, half a cycle apart. This is the
  /// "it's live on your home screen" beat.
  void _drawPulses(Canvas canvas) {
    final paint = Paint()..style = PaintingStyle.stroke;
    for (var k = 0; k < 2; k++) {
      final t = (phase + k * 0.5) % 1.0;
      final radius = _dialRadius * (0.95 + t * 1.5);
      final alpha = (1 - t) * 0.45;
      if (alpha <= 0.01) continue;
      paint
        ..strokeWidth = 4 * (1 - t) + 1
        ..color = accent.withValues(alpha: alpha);
      canvas.drawCircle(_dialCenter, radius, paint);
    }
  }

  void _drawDial(Canvas canvas) {
    // Rim ticks — the same instrument read as the real widget's dial.
    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4;
    const ticks = 20;
    for (var i = 0; i < ticks; i++) {
      final a = (-90 + i * (360 / ticks)) * math.pi / 180;
      final outer = _dialRadius * 0.94;
      final inner = outer - (i % 5 == 0 ? 17 : 10);
      tick.color = dim.withValues(alpha: i % 5 == 0 ? 0.55 : 0.32);
      canvas.drawLine(
        _dialCenter + Offset(math.cos(a) * inner, math.sin(a) * inner),
        _dialCenter + Offset(math.cos(a) * outer, math.sin(a) * outer),
        tick,
      );
    }

    // Gauge: swings between a low and a full reading, so it looks like a
    // meter tracking a voice rather than a fixed graphic.
    final swing = 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
    final sweep = (0.3 + 0.65 * swing) * 300;
    final rect = Rect.fromCircle(center: _dialCenter, radius: _dialRadius * 0.62);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      300 * math.pi / 180,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: 0.16),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep * math.pi / 180,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );

    canvas.drawCircle(_dialCenter, 14, Paint()..color = accent);
  }

  /// The card's right-hand column: a callsign line, a status line, and the
  /// bouncing level strip.
  void _drawCardText(Canvas canvas) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(410, 196, 96, 16),
        const Radius.circular(8),
      ),
      Paint()..color = dim.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(410, 228, 132, 22),
        const Radius.circular(11),
      ),
      Paint()..color = accent,
    );

    // Level bars. Doubling the phase keeps the wrap exact while letting them
    // bounce twice per loop, which reads livelier than a single slow sweep.
    final paint = Paint();
    const bars = 7;
    for (var i = 0; i < bars; i++) {
      final t = 0.5 +
          0.5 * math.sin((phase * 2 + i * 0.14) * 2 * math.pi);
      final h = 12 + 34 * t;
      final x = 410.0 + i * 22;
      paint.color = accent.withValues(alpha: 0.45 + 0.55 * t);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 302 - h / 2, 12, h),
          const Radius.circular(6),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant WidgetLoopPainter old) =>
      old.phase != phase || old.accent != accent;
}
