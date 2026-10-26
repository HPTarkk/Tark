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
  // The riders are their own avatars, as everyone in the room knows them. The
  // artwork's faces are fixed, so feelings are acted around them instead:
  // posture (tilt, sink, squash, shake), colour (drained to a cold grey when
  // hurt, flushed red when shouting) and weather (a rain cloud, an anger mark,
  // steam, a warm glow). That works on every avatar, a fox or a robot alike.

  void _you(Canvas canvas) {
    final pop = frame.youIn;
    if (pop <= 0) return;
    final sad = math.max(0.0, -frame.youMood);
    final happy = math.max(0.0, frame.youMood);
    final bob = math.sin(frame.ambient * math.pi * 4) * 2.2 * (1 - 0.6 * sad);
    final recoil = frame.flinch;
    final center = _youAt + Offset(-_dir * 9 * recoil, bob + 2 * recoil);
    _avatar(
      canvas,
      center: center,
      pop: pop * (1 - 0.06 * sad),
      image: frame.youImage,
      initial: frame.youInitial,
      tint: frame.youColor,
      squash: recoil,
      tilt: -_dir * 0.16 * sad,
      sink: 5 * sad,
      grey: 0.8 * sad,
      red: 0,
      blue: sad,
      glow: happy,
    );
    _impact(canvas, center, recoil);
    _cloud(canvas, center, sad);
    _tear(canvas, center, frame.tear);
  }

  void _them(Canvas canvas) {
    final pop = frame.themIn;
    if (pop <= 0) return;
    final landed = _domeLanded;
    final bob = math.sin(frame.ambient * math.pi * 4 + 1.3) * 2.2;
    // Shouting rocks them toward you; under the dome they just sulk.
    final shout = frame.waves * frame.themAnger * (1 - 0.75 * landed);
    final lean = math.sin(frame.ambient * math.pi * 12) * 2.8 * shout;
    final pulse = 0.75 + 0.25 * math.sin(frame.ambient * math.pi * 8);
    final center = _themAt + Offset(-_dir * lean, bob);
    _avatar(
      canvas,
      center: center,
      pop: pop * (1 - 0.05 * landed),
      image: frame.themImage,
      initial: frame.themInitial,
      tint: frame.themColor,
      squash: 0,
      tilt:
          _dir * 0.05 * frame.themAnger * math.sin(frame.ambient * math.pi * 6),
      sink: 2 * landed,
      grey: 0.4 * landed,
      red: frame.themAnger * pulse * (1 - 0.65 * landed),
      blue: 0,
      glow: 0,
    );
    _angerMark(canvas, center, frame.themAnger * (1 - 0.4 * landed), pulse);
    _steam(canvas, center, shout);
  }

  double get _domeLanded => frame.dome.clamp(0.0, 1.0);

  /// A colour matrix that drains toward grey, flushes red or chills blue.
  static List<double> _mood({
    required double grey,
    required double red,
    required double blue,
  }) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final k = 1 - grey;
    return <double>[
      lr * grey + k, lg * grey, lb * grey, 0, 70 * red, //
      lr * grey, lg * grey + k, lb * grey, 0, -28 * red - 6 * blue,
      lr * grey, lg * grey, lb * grey + k, 0, -28 * red + 34 * blue,
      0, 0, 0, 1, 0,
    ];
  }

  void _avatar(
    Canvas canvas, {
    required Offset center,
    required double pop,
    required ui.Image? image,
    required String initial,
    required Color tint,
    required double squash,
    required double tilt,
    required double sink,
    required double grey,
    required double red,
    required double blue,
    required double glow,
  }) {
    const r = _faceR;
    canvas.save();
    canvas.translate(center.dx, center.dy + r + sink);
    canvas.scale(pop * (1 + 0.08 * squash), pop * (1 - 0.08 * squash));
    canvas.translate(0, -r);

    // Ground shadow, left behind when the rider sinks or tilts.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(0, r + 14 - sink),
        width: r * 1.6,
        height: 9,
      ),
      Paint()..color = Colors.black.withValues(alpha: 0.22),
    );
    canvas.rotate(tilt);

    // A warm halo: the glow of being fine again.
    if (glow > 0.01) {
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(
          Offset.zero,
          r + 4 + i * 4.0,
          Paint()
            ..color = frame.youColor.withValues(alpha: 0.22 * glow / (i + 1))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4,
        );
      }
    }

    final filter = ColorFilter.matrix(_mood(grey: grey, red: red, blue: blue));
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
          )
          ..colorFilter = filter,
      );
    } else {
      final head = Rect.fromCircle(center: Offset.zero, radius: r);
      canvas.drawCircle(
        Offset.zero,
        r,
        Paint()
          ..shader = ui.Gradient.linear(head.topLeft, head.bottomRight, [
            Color.lerp(tint, Colors.white, 0.12)!,
            Color.lerp(tint, Colors.black, 0.28)!,
          ])
          ..colorFilter = filter,
      );
      final letter = TextPainter(
        text: TextSpan(
          text: initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            fontFamily: 'Vazirmatn',
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      letter.paint(canvas, Offset(-letter.width / 2, -letter.height / 2));
    }
    // Their colour as a ring, so the two read apart at a glance.
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()
        ..color = tint
        ..colorFilter = filter
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.restore();
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

  /// A tear sliding off the side away from them.
  void _tear(Canvas canvas, Offset center, double tear) {
    if (tear <= 0) return;
    final grow = (tear / 0.35).clamp(0.0, 1.0);
    final fall = ((tear - 0.35) / 0.65).clamp(0.0, 1.0);
    final at = center + Offset(-_dir * _faceR * 0.78, -2 + fall * fall * 34);
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

  /// The manga anger mark: four bulging strokes, throbbing.
  void _angerMark(Canvas canvas, Offset center, double anger, double pulse) {
    if (anger < 0.05) return;
    final at = center + Offset(_dir * _faceR * 0.7, -_faceR * 0.72);
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

  /// Where their words leave them: the edge of their avatar facing you.
  Offset get _mouth => _themAt + Offset(-_dir * _faceR * 0.6, _faceR * 0.3);

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
