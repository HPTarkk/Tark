import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The app's cartoon riders, shared by every little story the app tells
/// (the report story, the rating story): the same helmeted face that blinks,
/// smiles, frowns, shouts and cries, and the avatar sticker on its helmet.
///
/// Pure drawing on a canvas already translated into the caller's stage. No
/// state, no clipping, no blur, so a scene can draw two of these every frame
/// on the floor device.
abstract final class RiderCartoon {
  /// The face's radius on a scene's stage.
  static const double faceRadius = 38;

  /// One rider's face, standing on its chin at [center] + [faceRadius].
  ///
  /// [mood] runs -1 heartbroken … 0 flat … 1 beaming; [anger] 0 … 1;
  /// [lookToward] is -1 or 1 along x; [talking] opens the mouth into a shout;
  /// [tear] is a tear's fall 0 … 1; [ambient] is the scene's loop, which
  /// drives blinking and chatter.
  static void face(
    Canvas canvas, {
    required Offset center,
    required double pop,
    required Color color,
    required double mood,
    required double anger,
    required double lookToward,
    required double squash,
    required double talking,
    required double tear,
    double stretch = 0,
    double tilt = 0,
    Color? shift,
    double shiftBy = 0,
    required Color ink,
    required double ambient,
  }) {
    const r = faceRadius;
    if (shift != null && shiftBy > 0) {
      color = Color.lerp(color, shift, shiftBy)!;
    }
    canvas.save();
    canvas.translate(center.dx, center.dy + r);
    canvas.scale(
      pop * (1 + 0.08 * squash - 0.06 * stretch),
      pop * (1 - 0.08 * squash + 0.09 * stretch),
    );
    canvas.translate(0, -r);
    canvas.rotate(tilt);

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(center: Offset(0, r + 14), width: r * 1.6, height: 9),
      Paint()..color = Colors.black.withValues(alpha: 0.22),
    );

    // Head, lit from the top.
    final head = Rect.fromCircle(center: Offset.zero, radius: r);
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..shader = ui.Gradient.linear(head.topLeft, head.bottomRight, [
          Color.lerp(color, Colors.white, 0.18)!,
          Color.lerp(color, Colors.black, 0.22)!,
        ]),
    );

    // Helmet shell over the crown, with a visor stripe: they are riders.
    final shell = Color.lerp(color, Colors.black, 0.45)!;
    const from = math.pi + 0.42;
    const sweep = math.pi - 0.84;
    final left = Offset(math.cos(from) * r, math.sin(from) * r);
    final helmet = Path()
      ..moveTo(left.dx, left.dy)
      ..arcTo(head.inflate(3), from, sweep, false)
      ..quadraticBezierTo(0, -r * 0.18, left.dx, left.dy)
      ..close();
    canvas.drawPath(helmet, Paint()..color = shell);
    canvas.drawPath(
      Path()
        ..moveTo(-r * 0.62, -r * 0.42)
        ..quadraticBezierTo(0, -r * 0.62, r * 0.62, -r * 0.42),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );

    final look = lookToward * 2.4;

    // Cheeks, only while happy.
    final blush = math.max(0.0, mood);
    if (blush > 0) {
      final cheek = Paint()
        ..color = const Color(0xFFFF6B8A).withValues(alpha: 0.38 * blush);
      canvas.drawCircle(Offset(-r * 0.55, r * 0.28), 6, cheek);
      canvas.drawCircle(Offset(r * 0.55, r * 0.28), 6, cheek);
    }

    // Eyes: blink every loop, droop when sad, narrow when angry.
    final blinkT = (ambient * 2 + (anger > 0 ? 0.37 : 0)) % 1;
    final blink = blinkT > 0.94 ? 0.15 : 1.0;
    final sad = math.max(0.0, -mood);
    final eyeH = 9.5 * blink * (1 - 0.35 * anger) * (1 - 0.2 * sad);
    for (final side in const [-1.0, 1.0]) {
      final eye = Offset(side * r * 0.34, r * 0.0);
      canvas.drawOval(
        Rect.fromCenter(center: eye, width: 11, height: eyeH + 2),
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        eye + Offset(look, sad * 1.5),
        math.min(3.6, eyeH / 2),
        Paint()..color = ink,
      );
      // Brows: inner end down for anger, inner end up for sadness.
      final inner = side < 0 ? 1.0 : -1.0;
      final tilt = anger * 5 - sad * 4.5;
      final browY = -r * 0.24 - 2 * (1 - anger) + sad * 1;
      canvas.drawLine(
        eye + Offset(-inner * 6.5, browY - tilt * 0.4),
        eye + Offset(inner * 5, browY + tilt),
        Paint()
          ..color = ink
          ..strokeWidth = 2.8 + anger * 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Mouth: a curve that turns over from smile to frown, or an open shout.
    final mouthY = r * 0.42;
    if (talking > 0.05) {
      final open =
          (0.45 + 0.55 * math.sin(ambient * math.pi * 16).abs()) * talking;
      final mouth = Rect.fromCenter(
        center: Offset(look * 0.6, mouthY + 1),
        width: 15 + 4 * open,
        height: 4 + 10 * open,
      );
      canvas.drawOval(mouth, Paint()..color = const Color(0xFF3A0E12));
      canvas.drawOval(
        Rect.fromCenter(
          center: mouth.center + Offset(0, mouth.height * 0.22),
          width: mouth.width * 0.55,
          height: mouth.height * 0.35,
        ),
        Paint()..color = const Color(0xFFE5566B),
      );
    } else {
      final w = r * 0.36;
      final bend = mood * 9;
      canvas.drawPath(
        Path()
          ..moveTo(-w + look * 0.4, mouthY - bend * 0.35)
          ..quadraticBezierTo(
            look * 0.4,
            mouthY + bend,
            w + look * 0.4,
            mouthY - bend * 0.35,
          ),
        Paint()
          ..color = ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // A tear from the eye away from them, swelling then falling.
    if (tear > 0) {
      final grow = (tear / 0.35).clamp(0.0, 1.0);
      final fall = ((tear - 0.35) / 0.65).clamp(0.0, 1.0);
      final at = Offset(-lookToward * r * 0.42, r * 0.12 + fall * fall * 30);
      final size = 3.5 + 2.5 * grow;
      final drop = Path()
        ..moveTo(at.dx, at.dy - size * 1.6)
        ..quadraticBezierTo(at.dx + size, at.dy, at.dx, at.dy + size)
        ..quadraticBezierTo(at.dx - size, at.dy, at.dx, at.dy - size * 1.6)
        ..close();
      canvas.drawPath(
        drop,
        Paint()
          ..color = const Color(0xFF7FD3FF).withValues(alpha: 1 - fall * 0.8),
      );
    }

    canvas.restore();
  }

  /// A rider's avatar as a sticker on the helmet's [side] (-1 or 1).
  static void sticker(
    Canvas canvas, {
    required Offset center,
    required double pop,
    required double side,
    required ui.Image? image,
    required String initial,
    required Color tint,
    required double wobble,
    required double ambient,
  }) {
    // Lands a beat after the rider does, with its own little overshoot.
    final t = ((pop - 0.55) / 0.45).clamp(0.0, 1.2);
    if (t <= 0) return;
    const r = 13.0;
    final at = center + Offset(side * faceRadius * 0.7, -faceRadius * 0.62);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(side * (0.22 + 0.25 * wobble * math.sin(ambient * 40)));
    canvas.scale(t);
    canvas.drawCircle(
      const Offset(0, 1.5),
      r + 2.5,
      Paint()..color = Colors.black.withValues(alpha: 0.25),
    );
    canvas.drawCircle(Offset.zero, r + 2.5, Paint()..color = Colors.white);
    if (image != null) {
      final scale = 2 * r / math.min(image.width, image.height);
      final m = Matrix4.identity()
        ..translateByDouble(-r, -r, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
      canvas.drawCircle(
        Offset.zero,
        r,
        Paint()
          ..shader = ImageShader(
            image,
            TileMode.clamp,
            TileMode.clamp,
            m.storage,
            filterQuality: FilterQuality.medium,
          ),
      );
    } else {
      canvas.drawCircle(Offset.zero, r, Paint()..color = tint);
      final letter = TextPainter(
        text: TextSpan(
          text: initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
            fontFamily: 'Vazirmatn',
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      letter.paint(canvas, Offset(-letter.width / 2, -letter.height / 2));
    }
    canvas.restore();
  }

  /// An eight-point twinkle.
  static void sparkle(Canvas canvas, Offset at, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final len = i.isEven ? r * 1.8 : r * 0.6;
      final p = at + Offset(math.cos(a) * len, math.sin(a) * len);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }
}
