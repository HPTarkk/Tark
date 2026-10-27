import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/abuse_report.dart';

/// Everything one frame of the report scene needs, as plain numbers.
///
/// The sheet owns the controllers and turns them into this; the painter only
/// draws. Keeping it a value means the scene is one `CustomPaint` repainting
/// from one listenable, with no widget per character, which is what keeps it
/// at 60fps on the floor device (see `AppMotion`).
@immutable
class ReportSceneFrame {
  const ReportSceneFrame({
    required this.youIn,
    required this.themIn,
    required this.youMood,
    required this.themAnger,
    required this.bubble,
    required this.glyph,
    required this.waves,
    required this.wavePhase,
    required this.flinch,
    required this.tear,
    required this.dome,
    required this.envelope,
    required this.envelopeOn,
    required this.celebrate,
    required this.ambient,
    required this.rtl,
    required this.youColor,
    required this.themColor,
    required this.ink,
    required this.paper,
    required this.danger,
    required this.road,
    this.youImage,
    this.themImage,
    this.youInitial = '',
    this.themInitial = '',
  });

  /// Each rider's avatar artwork, once decoded; null draws their initial on
  /// their colour, the same fallback the roster uses.
  final ui.Image? youImage;
  final ui.Image? themImage;
  final String youInitial;
  final String themInitial;

  /// Entrance pop of each face, 0 → 1 (may overshoot).
  final double youIn;
  final double themIn;

  /// -1 heartbroken … 0 flat … 1 beaming.
  final double youMood;

  /// 0 calm … 1 furious.
  final double themAnger;

  /// Speech bubble size, 0 → 1 (may overshoot on a pop).
  final double bubble;

  /// What the bubble says; null is the generic angry scribble of the intro.
  final ReportReason? glyph;

  /// How hard the sound waves are hitting, 0 … 1.
  final double waves;
  final double wavePhase;

  /// A recoil impulse on "you", 0 … 1.
  final double flinch;

  /// A tear's fall, 0 … 1 (0 = none).
  final double tear;

  /// The mute dome's drop, 0 (above the stage) → 1 (landed, may overshoot).
  final double dome;

  /// The report envelope's flight, 0 (in your hands) → 1 (gone).
  final double envelope;
  final bool envelopeOn;

  /// Sparkles once the report is on its way, 0 … 1.
  final double celebrate;

  /// The ambient loop: bob, blink, chatter.
  final double ambient;

  /// The person reporting stands at the reading start, so in Persian the
  /// stage is mirrored. Only positions mirror; glyphs are never drawn
  /// backwards.
  final bool rtl;

  final Color youColor;
  final Color themColor;
  final Color ink;
  final Color paper;
  final Color danger;
  final Color road;
}

/// The two riders, the words between them, and what the app does about it.
///
/// Drawn on a fixed 340 × 200 stage scaled to fit. The avatars are painted
/// through an image shader into a circle, so there is still no clipping and
/// no blur anywhere in the scene.
class ReportScenePainter extends CustomPainter {
  ReportScenePainter(this.frame);

  final ReportSceneFrame frame;

  static const stage = Size(340, 200);
  static const double _faceR = 38;

  double get _dir => frame.rtl ? -1 : 1;

  /// Mirrors an x written for the left-to-right stage.
  double _x(double x) => frame.rtl ? stage.width - x : x;

  Offset get _youAt => Offset(_x(92), 120);
  Offset get _themAt => Offset(_x(250), 114);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / stage.width,
      size.height / stage.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - stage.width * scale) / 2,
      (size.height - stage.height * scale) / 2,
    );
    canvas.scale(scale);

    _road(canvas);
    _waves(canvas);
    _them(canvas);
    _bubble(canvas);
    _dome(canvas);
    _you(canvas);
    _envelope(canvas);
    _sparkles(canvas);

    canvas.restore();
  }

  // ── Backdrop ─────────────────────────────────────────────────────────────

  /// Riding together: a road line whose dashes roll under both of them.
  void _road(Canvas canvas) {
    final y = 172.0;
    final paint = Paint()
      ..color = frame.road
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const dash = 16.0;
    const gap = 14.0;
    final shift = (frame.ambient * (dash + gap) * 2) % (dash + gap);
    for (var x = 18.0 - shift; x < stage.width - 18; x += dash + gap) {
      final a = math.max(18.0, x);
      final b = math.min(stage.width - 18, x + dash);
      if (b > a) {
        canvas.drawLine(Offset(_x(a), y), Offset(_x(b), y), paint);
      }
    }
  }

  // ── Characters ───────────────────────────────────────────────────────────
  //
  // Cartoon riders with real faces that blink, frown, shout and cry, because
  // that is where the story's life is. What makes them *these* two riders is
  // the sticker on each helmet: their own avatar, slapped on the side the way
  // riders sticker their lids. It pops on after them and wobbles when they
  // flinch or shout.

  void _you(Canvas canvas) {
    final pop = frame.youIn;
    if (pop <= 0) return;
    final sad = math.max(0.0, -frame.youMood);
    final happy = math.max(0.0, frame.youMood);
    // Happy riders hop; sad ones barely move.
    final beat = frame.ambient * math.pi * 4;
    final hop = happy > 0.5
        ? math.sin(beat).abs() * 9 * (happy - 0.5) * 2
        : 0.0;
    final bob = math.sin(beat) * 2.2 * (1 - 0.7 * sad);
    final recoil = frame.flinch;
    final center =
        _youAt + Offset(-_dir * 9 * recoil, bob + 2 * recoil + 3 * sad - hop);
    _glow(canvas, center, happy);
    _face(
      canvas,
      center: center,
      pop: pop,
      color: frame.youColor,
      mood: frame.youMood,
      anger: 0,
      lookToward: _dir,
      squash: recoil + (hop > 0 ? (1 - hop / 9) * 0.6 : 0),
      talking: 0,
      tear: frame.tear,
      tilt: -_dir * 0.12 * sad,
      shift: const Color(0xFF8FA3B8),
      shiftBy: 0.45 * sad,
    );
    _sticker(
      canvas,
      center: center,
      pop: pop,
      side: -_dir,
      image: frame.youImage,
      initial: frame.youInitial,
      tint: frame.youColor,
      wobble: recoil,
    );
    _impact(canvas, center, recoil);
    _cloud(canvas, center, sad);
  }

  void _them(Canvas canvas) {
    final pop = frame.themIn;
    if (pop <= 0) return;
    final landed = _domeLanded;
    final bob = math.sin(frame.ambient * math.pi * 4 + 1.3) * 2.2;
    // Shouting rocks them toward you; under the dome they just sulk.
    final shout = frame.waves * (1 - 0.7 * landed);
    final syllable = math.sin(frame.ambient * math.pi * 12);
    final lean = syllable * 2.5 * shout;
    final pulse = 0.75 + 0.25 * math.sin(frame.ambient * math.pi * 8);
    final center = _themAt + Offset(-_dir * lean, bob);
    _face(
      canvas,
      center: center,
      pop: pop,
      color: frame.themColor,
      mood: -0.35 * frame.themAnger,
      anger: frame.themAnger,
      lookToward: -_dir,
      squash: 0,
      talking: shout,
      tear: 0,
      stretch: shout * syllable.abs(),
      shift: frame.danger,
      shiftBy: 0.35 * frame.themAnger * pulse * (1 - 0.6 * landed),
    );
    _sticker(
      canvas,
      center: center,
      pop: pop,
      side: _dir,
      image: frame.themImage,
      initial: frame.themInitial,
      tint: frame.themColor,
      wobble: shout * syllable.abs() * 0.6,
    );
    _angerMark(canvas, center, frame.themAnger * (1 - 0.4 * landed), pulse);
    _steam(canvas, center, shout);
  }

  double get _domeLanded => frame.dome.clamp(0.0, 1.0);

  void _face(
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
  }) {
    const r = _faceR;
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

    final ink = frame.ink;
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
    final blinkT = (frame.ambient * 2 + (anger > 0 ? 0.37 : 0)) % 1;
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
          (0.45 + 0.55 * math.sin(frame.ambient * math.pi * 16).abs()) *
          talking;
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

  /// Their avatar as a sticker on the helmet's outer side.
  void _sticker(
    Canvas canvas, {
    required Offset center,
    required double pop,
    required double side,
    required ui.Image? image,
    required String initial,
    required Color tint,
    required double wobble,
  }) {
    // Lands a beat after the rider does, with its own little overshoot.
    final t = ((pop - 0.55) / 0.45).clamp(0.0, 1.2);
    if (t <= 0) return;
    const r = 13.0;
    final at = center + Offset(side * _faceR * 0.7, -_faceR * 0.62);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(side * (0.22 + 0.25 * wobble * math.sin(frame.ambient * 40)));
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

  /// A warm halo: the glow of being fine again.
  void _glow(Canvas canvas, Offset center, double glow) {
    if (glow < 0.01) return;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        center,
        _faceR + 6 + i * 5.0,
        Paint()
          ..color = frame.youColor.withValues(alpha: 0.2 * glow / (i + 1))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  }

  /// The comic "pow" where the words land.
  void _impact(Canvas canvas, Offset center, double flinch) {
    if (flinch < 0.15) return;
    final at = center + Offset(_dir * (_faceR + 4), -8);
    final size = 6 + 10 * flinch;
    final path = Path();
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      final len = i.isEven ? size : size * 0.45;
      final p = at + Offset(math.cos(a) * len, math.sin(a) * len);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = const Color(0xFFFFC53D).withValues(alpha: flinch),
    );
  }

  /// A little rain cloud over someone having a bad ride.
  void _cloud(Canvas canvas, Offset center, double sad) {
    if (sad < 0.05) return;
    final at = center + Offset(0, -_faceR - 26 + 8 * (1 - sad));
    final paint = Paint()
      ..color = const Color(0xFF8E9AA6).withValues(alpha: 0.95 * sad);
    canvas.drawCircle(at + const Offset(-14, 2), 10, paint);
    canvas.drawCircle(at + const Offset(0, -4), 13, paint);
    canvas.drawCircle(at + const Offset(14, 2), 10, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: at + const Offset(0, 6), width: 46, height: 12),
        const Radius.circular(6),
      ),
      paint,
    );
    final drop = Paint()
      ..color = const Color(0xFF7FD3FF).withValues(alpha: 0.9 * sad)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 4; i++) {
      final p = (frame.ambient * 3 + i * 0.27) % 1;
      final x = at.dx - 15 + i * 10;
      final y = at.dy + 12 + p * 22;
      canvas.drawLine(
        Offset(x, y),
        Offset(x - 1.5, y + 5),
        drop..color = drop.color.withValues(alpha: 0.9 * sad * (1 - p)),
      );
    }
  }

  /// The manga anger mark: four bulging strokes, throbbing.
  void _angerMark(Canvas canvas, Offset center, double anger, double pulse) {
    if (anger < 0.05) return;
    // On the outer temple: under the helmet sticker, clear of the bubble.
    final at = center + Offset(_dir * _faceR * 0.98, _faceR * 0.12);
    final s = (7 + 2.5 * pulse) * anger;
    final paint = Paint()
      ..color = frame.danger
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var q = 0; q < 4; q++) {
      final sx = q.isEven ? 1.0 : -1.0;
      final sy = q < 2 ? 1.0 : -1.0;
      canvas.drawPath(
        Path()
          ..moveTo(at.dx + sx * s * 0.25, at.dy + sy * s)
          ..quadraticBezierTo(
            at.dx + sx * s * 0.3,
            at.dy + sy * s * 0.3,
            at.dx + sx * s,
            at.dy + sy * s * 0.25,
          ),
        paint,
      );
    }
  }

  /// Steam off a hot head, only while they are actually shouting.
  void _steam(Canvas canvas, Offset center, double shout) {
    if (shout < 0.05) return;
    for (var i = 0; i < 2; i++) {
      final p = (frame.ambient * 2.5 + i * 0.5) % 1;
      final side = i == 0 ? -1.0 : 1.0;
      final at =
          center +
          Offset(side * 16 + math.sin(p * 6) * 3, -_faceR - 4 - p * 22);
      canvas.drawCircle(
        at,
        3 + 5 * p,
        Paint()
          ..color = Colors.white.withValues(
            alpha: 0.5 * shout * math.sin(p * math.pi),
          ),
      );
    }
  }

  // ── What they said ───────────────────────────────────────────────────────

  Offset get _bubbleAt => _themAt + Offset(-_dir * 46, -76);

  Offset get _mouth => _themAt + Offset(-_dir * 3, _faceR * 0.42);

  /// Half the dome's width: where the glass stands either side of them.
  static const double _domeHalf = _faceR + 17;

  /// What still comes out of them under the glass: grey puffs that rise and
  /// pop before they reach it.
  void _mumble(Canvas canvas, double muffled) {
    if (muffled < 0.5 || frame.waves <= 0.01) return;
    final show = ((muffled - 0.5) * 2).clamp(0.0, 1.0);
    for (var i = 0; i < 3; i++) {
      final p = (frame.ambient * 2 + i / 3) % 1;
      final at =
          _mouth +
          Offset(-_dir * (10 + 14 * p), -6 - 30 * p + math.sin(p * 9) * 2);
      canvas.drawCircle(
        at,
        2 + 4 * p,
        Paint()
          ..color = const Color(
            0xFFB8C2CC,
          ).withValues(alpha: 0.75 * show * math.sin(p * math.pi)),
      );
    }
  }

  void _bubble(Canvas canvas) {
    final grow = frame.bubble;
    if (grow <= 0.01) return;
    final muffled = _domeLanded;
    _mumble(canvas, muffled);
    // Under the glass the words shrink to a mutter over their head: still
    // there, still changing with what you pick, but trapped in the dome.
    final scale = grow * (1 - 0.66 * muffled);
    if (scale <= 0.02) return;
    final jitter = Offset(
      math.sin(frame.ambient * math.pi * 22) * 1.2 * (1 - muffled),
      0,
    );
    final center = Offset.lerp(
      _bubbleAt,
      _themAt + const Offset(0, -_faceR - 4),
      muffled,
    )!;
    canvas.save();
    canvas.translate(center.dx + jitter.dx, center.dy);
    canvas.scale(scale);

    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 98, height: 52),
      const Radius.circular(20),
    );
    // Tail toward the speaker's mouth.
    final tail = Path()
      ..moveTo(_dir * 14, 20)
      ..lineTo(_dir * 40, 42)
      ..lineTo(_dir * 30, 18)
      ..close();
    final fill = Paint()
      ..color = Color.lerp(frame.paper, const Color(0xFF9AA4AE), muffled)!;
    final stroke = Paint()
      ..color = frame.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeJoin = StrokeJoin.round;
    // A mutter over their head has no one to point at.
    final pointed = muffled < 0.5;
    if (pointed) canvas.drawPath(tail, fill);
    canvas.drawRRect(body, fill);
    if (pointed) canvas.drawPath(tail, stroke);
    canvas.drawRRect(body, stroke);
    if (pointed) {
      // Re-cover the seam where the tail meets the body.
      canvas.drawLine(
        Offset(_dir * 15, 24.6),
        Offset(_dir * 29, 24.6),
        Paint()
          ..color = fill.color
          ..strokeWidth = 3,
      );
    }

    final hot = Color.lerp(frame.danger, const Color(0xFF59626B), muffled)!;
    switch (frame.glyph) {
      case null:
        _scribble(canvas, hot);
      case ReportReason.insult:
        _text(canvas, r'#@$%!', hot, 24);
      case ReportReason.threat:
        _bolt(canvas, const Offset(-16, 0), hot, 1);
        _bolt(canvas, const Offset(14, 0), hot, -1);
      case ReportReason.profile:
        _badTag(canvas, hot);
      case ReportReason.spam:
        _noise(canvas, hot);
      case ReportReason.other:
        _text(canvas, '?!', hot, 28);
    }
    canvas.restore();
  }

  void _text(Canvas canvas, String text, Color color, double size) {
    // Each character hops on its own beat: shouting, not printing.
    final painters = [
      for (final ch in text.characters)
        TextPainter(
          text: TextSpan(
            text: ch,
            style: TextStyle(
              color: color,
              fontSize: size,
              fontWeight: FontWeight.w900,
              fontFamily: 'Vazirmatn',
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    final total = painters.fold<double>(0, (sum, p) => sum + p.width);
    var x = -total / 2;
    for (var i = 0; i < painters.length; i++) {
      final p = painters[i];
      final hop =
          math.sin(frame.ambient * math.pi * 8 + i * 1.1) *
          2.5 *
          (1 - _domeLanded);
      p.paint(canvas, Offset(x, -p.height / 2 + hop));
      x += p.width;
    }
  }

  void _scribble(Canvas canvas, Color color) {
    final path = Path();
    final spin = frame.ambient * math.pi * 6;
    for (var i = 0; i <= 60; i++) {
      final t = i / 60;
      final a = spin + t * math.pi * 7;
      final p = Offset(-30 + 60 * t + math.cos(a) * 9, math.sin(a) * 11);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _bolt(Canvas canvas, Offset at, Color color, double lean) {
    final flash = 0.85 + 0.15 * math.sin(frame.ambient * math.pi * 10);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(0.18 * lean);
    canvas.scale(flash);
    final bolt = Path()
      ..moveTo(3, -18)
      ..lineTo(-8, 2)
      ..lineTo(-1, 2)
      ..lineTo(-4, 18)
      ..lineTo(9, -4)
      ..lineTo(2, -4)
      ..close();
    canvas.drawPath(bolt, Paint()..color = const Color(0xFFFFC53D));
    canvas.drawPath(
      bolt,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  /// A name tag with a picture square, struck through.
  void _badTag(Canvas canvas, Color color) {
    final tag = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 58, height: 28),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      tag,
      Paint()..color = frame.themColor.withValues(alpha: 0.35),
    );
    canvas.drawRRect(
      tag,
      Paint()
        ..color = frame.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawRect(
      const Rect.fromLTWH(-24, -9, 16, 18),
      Paint()..color = frame.ink.withValues(alpha: 0.55),
    );
    final line = Paint()
      ..color = frame.ink.withValues(alpha: 0.55)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-3, -5), const Offset(21, -5), line);
    canvas.drawLine(const Offset(-3, 4), const Offset(13, 4), line);
    // The strike swings in and out, like a stamp.
    final stamp = 0.8 + 0.2 * math.sin(frame.ambient * math.pi * 6).abs();
    final strike = Paint()
      ..color = color
      ..strokeWidth = 4 * stamp
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(-26, -15), const Offset(26, 15), strike);
    canvas.drawLine(const Offset(-26, 15), const Offset(26, -15), strike);
  }

  /// Blah-blah-blah: three zigzags that never stop.
  void _noise(Canvas canvas, Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (var row = 0; row < 3; row++) {
      final y = -12.0 + row * 12;
      final phase = frame.ambient * math.pi * 14 + row;
      final path = Path()..moveTo(-34, y);
      for (var i = 1; i <= 12; i++) {
        final x = -34 + i * (68 / 12);
        final amp = 4 * (0.6 + 0.4 * math.sin(phase + i));
        path.lineTo(x, y + (i.isOdd ? -amp : amp));
      }
      canvas.drawPath(path, paint);
    }
  }

  // ── The sound reaching you ───────────────────────────────────────────────

  void _waves(Canvas canvas) {
    final strength = frame.waves;
    if (strength <= 0.01) return;
    // A landed dome stops the sound at its glass: the waves start at their
    // mouth and break on the wall instead of crossing the road to you.
    final landed = _domeLanded;
    final glass = _themAt + Offset(-_dir * (_domeHalf - 3), 10);
    final from = Offset.lerp(
      _themAt + Offset(-_dir * (_faceR + 6), 6),
      _mouth + Offset(-_dir * 6, 0),
      landed,
    )!;
    final to = Offset.lerp(
      _youAt + Offset(_dir * (_faceR + 4), 2),
      glass,
      landed,
    )!;
    for (var i = 0; i < 3; i++) {
      final p = (frame.wavePhase + i / 3) % 1;
      final at = Offset.lerp(from, to, p)!;
      final fade = math.sin(p * math.pi);
      final alpha = (fade * strength).clamp(0.0, 1.0);
      if (alpha <= 0.02) continue;
      final h = (18 + 22 * p) * (1 - 0.45 * landed);
      final paint = Paint()
        ..color = frame.danger.withValues(alpha: alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      // A jagged arc, bowed toward you: it is meant to sting.
      final path = Path();
      const steps = 8;
      for (var k = 0; k <= steps; k++) {
        final t = k / steps;
        final y = -h / 2 + h * t;
        final bow = math.sin(t * math.pi) * 7 * -_dir;
        final zig = (k.isOdd ? 3.2 : -3.2) * -_dir;
        final pt = Offset(at.dx + bow + zig, at.dy + y);
        if (k == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(path, paint);
      // Bounced off the glass: the wave breaks into sparks.
      if (_domeLanded > 0.9 && p > 0.7) {
        final burst = (p - 0.7) / 0.3;
        for (var s = 0; s < 4; s++) {
          final a = -math.pi / 2 + (s - 1.5) * 0.6;
          canvas.drawCircle(
            at +
                Offset(
                  -_dir * math.cos(a) * -12 * burst,
                  math.sin(a) * 14 * burst,
                ),
            2.2 * (1 - burst),
            Paint()..color = frame.danger.withValues(alpha: 0.7 * (1 - burst)),
          );
        }
      }
    }
  }

  // ── What the app does about it ───────────────────────────────────────────

  void _dome(Canvas canvas) {
    final d = frame.dome;
    if (d <= 0.001) return;
    final base = _themAt + const Offset(0, _faceR + 12);
    const w = _domeHalf * 2;
    const h = _faceR * 2 + 34;
    // Falls in from above; past 1 the spring overshoot squashes it on landing.
    final drop = (1 - d.clamp(0.0, 1.0)) * -190;
    final squash = d > 1 ? (d - 1) : 0.0;
    canvas.save();
    canvas.translate(base.dx, base.dy + drop);
    canvas.scale(1 + squash * 0.6, 1 - squash * 0.6);

    final glass = Path()
      ..moveTo(-w / 2, 0)
      ..lineTo(-w / 2, -h * 0.45)
      ..arcToPoint(
        Offset(w / 2, -h * 0.45),
        radius: const Radius.elliptical(w / 2, h * 0.55),
      )
      ..lineTo(w / 2, 0)
      ..close();
    canvas.drawPath(
      glass,
      Paint()..color = const Color(0xFFBFE6FF).withValues(alpha: 0.16),
    );
    canvas.drawPath(
      glass,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
    // Glint.
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(0, -h * 0.45),
        width: w - 22,
        height: h * 1.0 - 22,
      ),
      math.pi * 1.12,
      0.55,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    // Base plate.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, 2), width: w + 14, height: 8),
        const Radius.circular(4),
      ),
      Paint()..color = const Color(0xFF8C98A4),
    );
    // A speaker with a slash, on the knob at the top.
    final knob = Offset(0, -h - 0.5);
    canvas.drawCircle(knob, 11, Paint()..color = frame.paper);
    canvas.drawCircle(
      knob,
      11,
      Paint()
        ..color = frame.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final speaker = Path()
      ..moveTo(knob.dx - 6, knob.dy - 2.5)
      ..lineTo(knob.dx - 3, knob.dy - 2.5)
      ..lineTo(knob.dx + 1.5, knob.dy - 6)
      ..lineTo(knob.dx + 1.5, knob.dy + 6)
      ..lineTo(knob.dx - 3, knob.dy + 2.5)
      ..lineTo(knob.dx - 6, knob.dy + 2.5)
      ..close();
    canvas.drawPath(speaker, Paint()..color = frame.ink);
    canvas.drawLine(
      knob + const Offset(-7, -7),
      knob + const Offset(7, 7),
      Paint()
        ..color = frame.danger
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  void _envelope(Canvas canvas) {
    if (!frame.envelopeOn) return;
    final t = frame.envelope;
    // Pops up in front of you, then takes off over the far corner.
    final lift = Curves.easeOutBack.transform((t / 0.3).clamp(0.0, 1.0));
    final fly = Curves.easeIn.transform(((t - 0.3) / 0.7).clamp(0.0, 1.0));
    final start = _youAt + Offset(_dir * 6, 34 - 26 * lift);
    final end = Offset(_x(stage.width + 40), -40);
    final control = Offset(_x(200), -10);
    final at = _quad(start, control, end, fly);
    final angle = -_dir * (0.15 + 0.5 * fly);
    final size = (0.4 + 0.6 * lift) * (1 - 0.35 * fly);

    // Dotted trail.
    if (fly > 0) {
      for (var i = 1; i <= 6; i++) {
        final back = fly - i * 0.06;
        if (back <= 0) break;
        canvas.drawCircle(
          _quad(start, control, end, back),
          2.2,
          Paint()..color = frame.paper.withValues(alpha: 0.5 - i * 0.07),
        );
      }
    }

    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    canvas.scale(size);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 40, height: 28),
      const Radius.circular(4),
    );
    canvas.drawRRect(body, Paint()..color = frame.paper);
    final edge = Paint()
      ..color = frame.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(body, edge);
    canvas.drawPath(
      Path()
        ..moveTo(-20, -14)
        ..lineTo(0, 3)
        ..lineTo(20, -14),
      edge,
    );
    canvas.drawCircle(const Offset(0, 3), 4.5, Paint()..color = frame.danger);
    canvas.restore();
  }

  Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  void _sparkles(Canvas canvas) {
    final c = frame.celebrate;
    if (c <= 0) return;
    final center = _youAt + const Offset(0, -6);
    const colors = [
      Color(0xFFFFC53D),
      Color(0xFF7FD3FF),
      Color(0xFFFF6B8A),
      Color(0xFF7EE787),
    ];
    for (var i = 0; i < 10; i++) {
      final a = -math.pi / 2 + (i - 4.5) * 0.36;
      final dist = _faceR + 8 + 34 * Curves.easeOut.transform(c);
      final at = center + Offset(math.cos(a) * dist, math.sin(a) * dist);
      final alpha = (1 - c).clamp(0.0, 1.0);
      final r = 3.5 + (i % 3);
      _star(
        canvas,
        at,
        r * (1 - 0.4 * c),
        colors[i % 4].withValues(alpha: alpha),
      );
    }
  }

  void _star(Canvas canvas, Offset at, double r, Color color) {
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

  @override
  bool shouldRepaint(ReportScenePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
