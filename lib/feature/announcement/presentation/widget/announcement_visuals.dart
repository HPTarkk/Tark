import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entity/announcement.dart';

/// How each kind of announcement looks: its colour, and the ink on it.
///
/// The accents come from the two families the app already has — the radio's
/// amber and red, the website's forest greens — so every kind reads as Tarkk
/// while still being told apart at a glance.
class AnnouncementStyle {
  const AnnouncementStyle({required this.accent, required this.onAccent});

  final Color accent;

  /// Label and icon on a filled [accent].
  final Color onAccent;

  static AnnouncementStyle of(AnnouncementCategory category) {
    final forest = AppColors.forest;
    return switch (category) {
      AnnouncementCategory.gift => AnnouncementStyle(
        accent: AppColors.amber,
        onAccent: AppColors.background,
      ),
      AnnouncementCategory.feature => AnnouncementStyle(
        accent: forest.lagoon,
        onAccent: forest.onAccent,
      ),
      AnnouncementCategory.news => AnnouncementStyle(
        accent: forest.mint,
        onAccent: forest.onAccent,
      ),
      AnnouncementCategory.tip => AnnouncementStyle(
        accent: forest.lime,
        onAccent: forest.onAccent,
      ),
      AnnouncementCategory.event => AnnouncementStyle(
        accent: forest.leaf,
        onAccent: forest.onAccent,
      ),
      AnnouncementCategory.alert => AnnouncementStyle(
        accent: AppColors.red,
        onAccent: AppColors.background,
      ),
    };
  }

  /// The confetti and dust: the accent among its neighbours, so a burst is
  /// festive without leaving the product's colours.
  static List<Color> festive() {
    final forest = AppColors.forest;
    return [
      AppColors.amber,
      forest.lime,
      forest.lagoon,
      AppColors.amber,
      forest.mint,
      AppColors.red,
    ];
  }
}

/// 0 → 1 over [begin]..[end] of [t], shaped by [curve].
double _seg(double t, double begin, double end, [Curve curve = Curves.linear]) {
  if (t <= begin) return 0;
  if (t >= end) return 1;
  return curve.transform((t - begin) / (end - begin));
}

/// The same, but the shape may leave 0..1 (an overshooting curve's peak).
double _segRaw(double t, double begin, double end, Curve curve) {
  if (t <= begin) return curve.transform(0);
  if (t >= end) return curve.transform(1);
  return curve.transform((t - begin) / (end - begin));
}

Color _lighten(Color c, double amount) => Color.lerp(c, Colors.white, amount)!;
Color _darken(Color c, double amount) => Color.lerp(c, Colors.black, amount)!;

/// A small random number that is always the same for the same [i]: every
/// burst of confetti is identical, so a screenshot test can hold it still.
double _hash(int i, [int salt = 0]) {
  final x = math.sin((i + 1) * 12.9898 + salt * 78.233) * 43758.5453;
  return x - x.floorToDouble();
}

/// A four-pointed sparkle with pinched sides.
Path _sparkle(Offset c, double r, {double pinch = 0.22}) {
  final inner = r * pinch;
  final path = Path()..moveTo(c.dx, c.dy - r);
  path
    ..quadraticBezierTo(c.dx + inner, c.dy - inner, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + inner, c.dy + inner, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - inner, c.dy + inner, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - inner, c.dy - inner, c.dx, c.dy - r)
    ..close();
  return path;
}

/// [path] drawn only as far as [t] along its length, for lines that sketch
/// themselves in.
Path _partial(Path path, double t) {
  if (t >= 1) return path;
  final out = Path();
  if (t <= 0) return out;
  final metrics = path.computeMetrics().toList();
  final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
  var left = total * t;
  for (final m in metrics) {
    if (left <= 0) break;
    out.addPath(m.extractPath(0, math.min(left, m.length)), Offset.zero);
    left -= m.length;
  }
  return out;
}

// ── Emblem ──────────────────────────────────────────────────────────────────

/// The mark at the top of an announcement. Each category has its own, and
/// its own entrance, so a gift *feels* like a gift before a word is read:
///
/// - **gift** — the box drops in, squashes, shivers, and its lid pops off in
///   a burst of confetti; the lid then floats, bobbing, over a glow.
/// - **feature** — a spark ignites, spins open into a star and throws its
///   rays; two little stars pop out beside it and twinkle.
/// - **news** — the mast sketches itself up from its feet, its lamp lights,
///   and the first broadcast rolls out of it.
/// - **tip** — the bulb is drawn, its filament stutters on like a real one,
///   and its rays fan out one by one.
/// - **event** — the calendar lands, last page tears up over the rings, and
///   the day is circled.
/// - **alert** — the beacon drops, rattles, and starts to turn and sound.
///
/// [arrival] runs 0 → 1 once; a quiet loop carries on after it. Under
/// reduced motion the emblem fades in already settled and holds still.
class AnnouncementEmblem extends StatefulWidget {
  const AnnouncementEmblem({
    required this.category,
    required this.arrival,
    this.size = 96,
    super.key,
  });

  final AnnouncementCategory category;
  final Animation<double> arrival;
  final double size;

  @override
  State<AnnouncementEmblem> createState() => _AnnouncementEmblemState();
}

class _AnnouncementEmblemState extends State<AnnouncementEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: _loopLength(widget.category),
  );

  static Duration _loopLength(AnnouncementCategory c) => switch (c) {
    AnnouncementCategory.alert => const Duration(milliseconds: 1800),
    AnnouncementCategory.news => const Duration(milliseconds: 2400),
    _ => const Duration(milliseconds: 3200),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.3);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final style = AnnouncementStyle.of(widget.category);
    final painter = _EmblemPainter(
      category: widget.category,
      arrival: widget.arrival,
      loop: _loop,
      accent: style.accent,
      onAccent: style.onAccent,
      card: AppColors.card,
      festive: AnnouncementStyle.festive(),
      reduced: reduced,
    );
    Widget emblem = RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.size * 1.7, widget.size),
        painter: painter,
      ),
    );
    if (reduced) {
      emblem = FadeTransition(opacity: widget.arrival, child: emblem);
    }
    return ExcludeSemantics(child: emblem);
  }
}

class _EmblemPainter extends CustomPainter {
  _EmblemPainter({
    required this.category,
    required this.arrival,
    required this.loop,
    required this.accent,
    required this.onAccent,
    required this.card,
    required this.festive,
    required this.reduced,
  }) : super(repaint: Listenable.merge([arrival, loop]));

  final AnnouncementCategory category;
  final Animation<double> arrival;
  final Animation<double> loop;
  final Color accent;
  final Color onAccent;
  final Color card;
  final List<Color> festive;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    // Under reduced motion the arrival is a fade (see the widget); what is
    // painted is the settled frame.
    final a = reduced ? 1.0 : arrival.value;
    final l = loop.value;
    final c = size.center(Offset.zero);
    final u = size.height / 100;
    switch (category) {
      case AnnouncementCategory.gift:
        _gift(canvas, c, u, a, l);
      case AnnouncementCategory.feature:
        _feature(canvas, c, u, a, l);
      case AnnouncementCategory.news:
        _news(canvas, c, u, a, l);
      case AnnouncementCategory.tip:
        _tip(canvas, c, u, a, l);
      case AnnouncementCategory.event:
        _event(canvas, c, u, a, l);
      case AnnouncementCategory.alert:
        _alert(canvas, c, u, a, l);
    }
  }

  // The ambient loop fades in as the arrival finishes, so the hand-over from
  // the entrance to the idle motion has no seam.
  double _idle(double a) => _seg(a, 0.82, 1);

  void _glow(Canvas canvas, Offset at, double radius, double alpha) {
    if (alpha <= 0) return;
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = ui.Gradient.radial(at, radius, [
          accent.withValues(alpha: alpha.clamp(0, 1)),
          accent.withValues(alpha: 0),
        ]),
    );
  }

  void _twinkle(Canvas canvas, Offset at, double r, double alpha, Color color) {
    if (alpha <= 0.01 || r <= 0) return;
    canvas.drawPath(
      _sparkle(at, r),
      Paint()..color = color.withValues(alpha: alpha.clamp(0, 1)),
    );
  }

  // ── gift ──

  void _gift(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final drop = _segRaw(a, 0, 0.3, Curves.easeOutBack);
    final squash = math.sin(math.pi * _seg(a, 0.24, 0.4));
    final shake = _seg(a, 0.4, 0.56);
    final pop = _seg(a, 0.56, 0.68, AppMotion.easeOut);
    final settle = _seg(a, 0.68, 0.96, Curves.easeInOut);
    final opacity = _seg(a, 0, 0.1);
    if (opacity <= 0) return;

    final floor = c.dy + 34 * u;
    final boxW = 50 * u;
    final boxH = 36 * u;
    final mouth = Offset(c.dx, floor - boxH);

    // Light from inside the open box, then confetti out of it.
    _glow(
      canvas,
      mouth,
      44 * u,
      0.5 * pop * (1 - 0.45 * settle) + idle * 0.08 * math.sin(l * 2 * math.pi),
    );
    final burst = _seg(a, 0.56, 1);
    if (burst > 0 && burst < 1) {
      final fade = 1 - _seg(a, 0.82, 1);
      for (var i = 0; i < 22; i++) {
        final angle = -math.pi / 2 + (_hash(i) - 0.5) * math.pi * 0.95;
        final speed = (70 + 70 * _hash(i, 1)) * u;
        final time = burst * 1.15;
        final p = Offset(
          mouth.dx + math.cos(angle) * speed * time,
          mouth.dy + math.sin(angle) * speed * time + 70 * u * time * time,
        );
        final paint = Paint()
          ..color = festive[i % festive.length].withValues(alpha: fade);
        canvas.save();
        canvas.translate(p.dx, p.dy);
        canvas.rotate((_hash(i, 2) - 0.5) * 14 * time);
        if (i.isEven) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: Offset.zero, width: 6 * u, height: 3 * u),
              Radius.circular(u),
            ),
            paint,
          );
        } else {
          canvas.drawCircle(Offset.zero, 1.9 * u, paint);
        }
        canvas.restore();
      }
    }

    canvas.save();
    canvas.translate(0, -70 * u * (1 - drop));
    // Squash on landing, against the floor.
    canvas.translate(c.dx, floor);
    canvas.scale(1 + 0.1 * squash, 1 - 0.14 * squash);
    // The shiver before it opens: three quick wobbles, dying away.
    canvas.rotate(0.08 * math.sin(shake * math.pi * 6) * (1 - shake));
    canvas.translate(-c.dx, -floor);

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(c.dx - boxW / 2, floor - boxH, boxW, boxH),
      Radius.circular(6 * u),
    );
    final layer = Paint()..color = Colors.white.withValues(alpha: opacity);
    canvas.saveLayer(body.outerRect.inflate(80 * u), layer);
    canvas.drawRRect(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          body.outerRect.topLeft,
          body.outerRect.bottomRight,
          [accent, _darken(accent, 0.25)],
        ),
    );
    final ribbon = _lighten(accent, 0.6);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(c.dx, floor - boxH / 2),
        width: 9 * u,
        height: boxH,
      ),
      Paint()..color = ribbon,
    );
    // The inside of the box, seen once the lid is off.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c.dx - boxW / 2, floor - boxH, boxW, 5 * u * pop),
        Radius.circular(2 * u),
      ),
      Paint()..color = _darken(accent, 0.5).withValues(alpha: pop),
    );

    // The lid: off with a twist, then floating above the box.
    final lift =
        -30 * u * pop +
        13 * u * settle +
        idle * 2.4 * u * math.sin(l * 2 * math.pi);
    final tilt =
        -0.34 * pop +
        0.26 * settle +
        idle * 0.04 * math.sin(l * 2 * math.pi + 1);
    canvas.save();
    canvas.translate(c.dx, floor - boxH + lift);
    canvas.rotate(tilt);
    final lid = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(0, -6 * u),
        width: boxW + 8 * u,
        height: 13 * u,
      ),
      Radius.circular(4 * u),
    );
    canvas.drawRRect(lid, Paint()..color = _lighten(accent, 0.08));
    canvas.drawRect(
      Rect.fromCenter(center: Offset(0, -6 * u), width: 9 * u, height: 13 * u),
      Paint()..color = ribbon,
    );
    // The bow.
    final bow = Paint()
      ..color = ribbon
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * u
      ..strokeCap = StrokeCap.round;
    for (final side in const [-1.0, 1.0]) {
      canvas.save();
      canvas.translate(0, -13 * u);
      canvas.rotate(side * 0.6);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(side * 7 * u, -5 * u),
          width: 13 * u,
          height: 9 * u,
        ),
        bow,
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(0, -13 * u), 3 * u, Paint()..color = ribbon);
    canvas.restore();
    canvas.restore(); // layer
    canvas.restore();

    // Sparkles that keep catching the light once it is open.
    for (var i = 0; i < 3; i++) {
      final phase = l * 2 * math.pi + i * 2.1;
      final s = math.pow(math.max(0, math.sin(phase)), 3).toDouble();
      final at = Offset(
        c.dx + (i - 1) * 34 * u + (i == 1 ? 6 * u : 0),
        c.dy - (i == 1 ? 38 : 18) * u,
      );
      _twinkle(canvas, at, 5 * u * s, idle * s, _lighten(accent, 0.4));
    }
  }

  // ── feature ──

  void _feature(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final dot = _seg(a, 0, 0.16, AppMotion.easeOut);
    final open = _segRaw(a, 0.12, 0.5, Curves.easeOutBack);
    final openLinear = _seg(a, 0.12, 0.5);
    final rays = _seg(a, 0.26, 0.72);
    final r = 30 * u;
    final at = Offset(c.dx, c.dy);

    _glow(
      canvas,
      at,
      50 * u,
      0.32 * openLinear + idle * 0.06 * math.sin(l * 2 * math.pi),
    );

    // The ignition: a point of light before the star.
    if (dot > 0 && openLinear < 1) {
      canvas.drawCircle(
        at,
        7 * u * dot * (1 - openLinear),
        Paint()..color = _lighten(accent, 0.5),
      );
    }

    // Rays thrown out once: each a dash that leaves the star and is gone.
    if (rays > 0 && rays < 1) {
      final paint = Paint()
        ..color = accent.withValues(alpha: 1 - rays)
        ..strokeWidth = 3 * u
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 8; i++) {
        final angle = i * math.pi / 4 + math.pi / 8;
        final head = r * 0.9 + 26 * u * AppMotion.easeOut.transform(rays);
        final tail = r * 0.9 + 26 * u * Curves.easeIn.transform(rays);
        final dir = Offset(math.cos(angle), math.sin(angle));
        canvas.drawLine(at + dir * tail, at + dir * head, paint);
      }
    }
    // Afterwards, short rays that breathe.
    if (idle > 0) {
      final paint = Paint()
        ..strokeWidth = 2.4 * u
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 4; i++) {
        final angle = i * math.pi / 2 + math.pi / 4;
        final pulse = 0.5 + 0.5 * math.sin(l * 2 * math.pi + i * 1.6);
        final dir = Offset(math.cos(angle), math.sin(angle));
        paint.color = accent.withValues(alpha: idle * (0.25 + 0.5 * pulse));
        canvas.drawLine(
          at + dir * (r * 0.86),
          at + dir * (r * 0.86 + (5 + 5 * pulse) * u),
          paint,
        );
      }
    }

    // The star itself: spins open from a quarter turn, then sways.
    if (open > 0) {
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(
        -math.pi / 2 * (1 - openLinear) +
            idle * 0.07 * math.sin(l * 2 * math.pi),
      );
      canvas.scale(math.max(0, open));
      final star = _sparkle(Offset.zero, r);
      canvas.drawPath(
        star,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(-r, -r),
            Offset(r, r),
            [_lighten(accent, 0.35), accent, _darken(accent, 0.2)],
            const [0, 0.5, 1],
          ),
      );
      canvas.drawPath(
        _sparkle(Offset(-r * 0.1, -r * 0.12), r * 0.32),
        Paint()..color = Colors.white.withValues(alpha: 0.55),
      );
      canvas.restore();
    }

    // Two little stars that pop out after it.
    final sats = [
      (Offset(c.dx + 36 * u, c.dy - 28 * u), 9.0, 0.56),
      (Offset(c.dx - 38 * u, c.dy + 22 * u), 7.0, 0.64),
    ];
    for (var i = 0; i < sats.length; i++) {
      final (pos, size, start) = sats[i];
      final pop = _segRaw(a, start, start + 0.22, Curves.easeOutBack);
      if (pop <= 0) continue;
      final tw =
          idle * math.pow(math.max(0, math.sin(l * 2 * math.pi + i * 2.4)), 2);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(l * math.pi * (i.isEven ? 1 : -1) * idle);
      canvas.drawPath(
        _sparkle(Offset.zero, size * u * pop * (1 + 0.25 * tw)),
        Paint()..color = _lighten(accent, 0.25 + 0.3 * tw),
      );
      canvas.restore();
    }
  }

  // ── news ──

  void _news(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final build = _seg(a, 0, 0.42, Curves.easeInOut);
    final lamp = _segRaw(a, 0.36, 0.52, Curves.easeOutBack);
    final first = _seg(a, 0.46, 1, AppMotion.easeOut);
    final top = Offset(c.dx, c.dy - 20 * u);
    final feet = c.dy + 40 * u;

    final mast = Path()
      ..moveTo(c.dx - 16 * u, feet)
      ..lineTo(c.dx, top.dy + 8 * u)
      ..lineTo(c.dx + 16 * u, feet);
    // Cross-bracing, bottom to top, so the sketch climbs.
    for (var i = 0; i < 3; i++) {
      final y0 = feet - i * 15 * u;
      final y1 = y0 - 15 * u;
      double half(double y) =>
          16 * u * (y - top.dy - 8 * u) / (feet - top.dy - 8 * u);
      mast
        ..moveTo(c.dx - half(y0), y0)
        ..lineTo(c.dx + half(y1), y1)
        ..moveTo(c.dx + half(y0), y0)
        ..lineTo(c.dx - half(y1), y1);
    }
    canvas.drawPath(
      _partial(mast, build),
      Paint()
        ..color = _lighten(accent, 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2 * u
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final wave = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    void arcs(double t, double alpha) {
      if (alpha <= 0) return;
      final radius = 12 * u + 46 * u * t;
      final fade = (t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85) * alpha;
      wave
        ..color = accent.withValues(alpha: fade.clamp(0, 1))
        ..strokeWidth = (3.6 - 1.8 * t) * u;
      final rect = Rect.fromCircle(center: top, radius: radius);
      const sweep = math.pi * 0.46;
      canvas.drawArc(rect, -sweep / 2, sweep, false, wave);
      canvas.drawArc(rect, math.pi - sweep / 2, sweep, false, wave);
    }

    // The first broadcast, sent by the arrival itself, then the loop.
    if (first > 0 && first < 1) arcs(first, 1);
    for (var i = 0; i < 3; i++) {
      arcs((l + i / 3) % 1, idle);
    }

    if (lamp > 0) {
      _glow(
        canvas,
        top,
        22 * u,
        0.5 * _seg(a, 0.36, 0.52) + idle * 0.15 * math.sin(l * 4 * math.pi),
      );
      canvas.drawCircle(
        top,
        7 * u * math.max(0, lamp),
        Paint()
          ..shader = ui.Gradient.radial(top - Offset(2 * u, 2 * u), 8 * u, [
            _lighten(accent, 0.55),
            accent,
          ]),
      );
    }
  }

  // ── tip ──

  /// The filament's stutter: on, nearly off, on, flicker, on for good.
  static double _flicker(double a) {
    const keys = [
      (0.38, 0.0),
      (0.44, 1.0),
      (0.49, 0.12),
      (0.55, 0.85),
      (0.6, 0.3),
      (0.7, 1.0),
    ];
    if (a <= keys.first.$1) return 0;
    for (var i = 1; i < keys.length; i++) {
      final (t1, v1) = keys[i];
      if (a <= t1) {
        final (t0, v0) = keys[i - 1];
        return ui.lerpDouble(v0, v1, (a - t0) / (t1 - t0))!;
      }
    }
    return 1;
  }

  void _tip(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final draw = _seg(a, 0, 0.36, Curves.easeInOut);
    final lit =
        _flicker(a) *
        (1 - idle * 0.12 * (0.5 + 0.5 * math.sin(l * 2 * math.pi)));
    final bulbC = Offset(c.dx, c.dy - 10 * u);
    final r = 24 * u;

    _glow(canvas, bulbC, 54 * u, 0.42 * lit);

    final outline = Path()
      ..addArc(
        Rect.fromCircle(center: bulbC, radius: r),
        math.pi * 0.78,
        math.pi * 1.44,
      )
      ..moveTo(
        bulbC.dx + r * math.cos(math.pi * 0.22),
        bulbC.dy + r * math.sin(math.pi * 0.22),
      )
      ..lineTo(c.dx + 9 * u, c.dy + 26 * u)
      ..lineTo(c.dx - 9 * u, c.dy + 26 * u)
      ..lineTo(
        bulbC.dx + r * math.cos(math.pi * 0.78),
        bulbC.dy + r * math.sin(math.pi * 0.78),
      );

    if (lit > 0) {
      canvas.drawPath(
        outline,
        Paint()..color = accent.withValues(alpha: 0.85 * lit),
      );
    }
    canvas.drawPath(
      _partial(outline, draw),
      Paint()
        ..color = _lighten(accent, 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4 * u
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    // Filament.
    final filament = Path()
      ..moveTo(c.dx - 7 * u, c.dy + 14 * u)
      ..lineTo(c.dx - 7 * u, c.dy - 4 * u)
      ..lineTo(c.dx - 3.5 * u, c.dy - 10 * u)
      ..lineTo(c.dx, c.dy - 4 * u)
      ..lineTo(c.dx + 3.5 * u, c.dy - 10 * u)
      ..lineTo(c.dx + 7 * u, c.dy - 4 * u)
      ..lineTo(c.dx + 7 * u, c.dy + 14 * u);
    canvas.drawPath(
      _partial(filament, _seg(a, 0.16, 0.4)),
      Paint()
        ..color = Color.lerp(_darken(accent, 0.2), Colors.white, lit)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * u
        ..strokeJoin = StrokeJoin.round,
    );
    // The screw base.
    final base = Paint()
      ..color = _lighten(accent, 0.15).withValues(alpha: _seg(a, 0.2, 0.36))
      ..strokeWidth = 3.4 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(c.dx - 8 * u, c.dy + 32 * u),
      Offset(c.dx + 8 * u, c.dy + 32 * u),
      base,
    );
    canvas.drawLine(
      Offset(c.dx - 5 * u, c.dy + 38 * u),
      Offset(c.dx + 5 * u, c.dy + 38 * u),
      base,
    );

    // Rays fanning out over the top, one after another.
    final ray = Paint()
      ..strokeWidth = 3 * u
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 7; i++) {
      final start = 0.7 + 0.03 * i;
      final grow = _segRaw(a, start, start + 0.16, Curves.easeOutBack);
      if (grow <= 0) continue;
      final angle = math.pi + math.pi * (i + 0.5) / 7;
      final pulse = idle * 0.5 * (1 + math.sin(l * 2 * math.pi + i));
      final dir = Offset(math.cos(angle), math.sin(angle));
      final from = bulbC + dir * (r + 7 * u);
      ray.color = accent.withValues(alpha: (0.6 + 0.4 * lit).clamp(0, 1));
      canvas.drawLine(
        from,
        from + dir * (7 + 4 * pulse) * u * math.max(0, grow),
        ray,
      );
    }
  }

  // ── event ──

  void _event(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final land = _segRaw(a, 0, 0.26, Curves.easeOutBack);
    final flip = _seg(a, 0.3, 0.66, Curves.easeInOut);
    final circle = _seg(a, 0.66, 0.92, AppMotion.easeOut);
    if (land <= 0) return;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(math.max(0, land));
    canvas.rotate(-0.05 * (1 - _seg(a, 0, 0.3)));
    canvas.translate(-c.dx, -c.dy);

    final w = 62 * u;
    final h = 60 * u;
    final card = Rect.fromCenter(
      center: Offset(c.dx, c.dy + 4 * u),
      width: w,
      height: h,
    );
    final rr = RRect.fromRectAndRadius(card, Radius.circular(9 * u));
    final head = 17 * u;
    canvas.drawRRect(rr, Paint()..color = this.card);
    canvas.drawRRect(
      rr,
      Paint()
        ..color = accent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2 * u,
    );
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      Rect.fromLTWH(card.left, card.top, w, head),
      Paint()..color = accent,
    );
    canvas.restore();

    // This page: a grid of days, one of them about to be circled.
    final dotPaint = Paint()..color = accent.withValues(alpha: 0.45);
    Offset cell(int row, int col) => Offset(
      card.left + w * (col + 1) / 5,
      card.top + head + (h - head) * (row + 1) / 4,
    );
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 4; col++) {
        canvas.drawCircle(cell(row, col), 2.4 * u, dotPaint);
      }
    }
    final day = cell(1, 2);
    if (circle > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: day, radius: 7.5 * u),
        -math.pi * 0.6,
        math.pi * 2 * circle,
        false,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6 * u
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(day, 3.2 * u, Paint()..color = accent);
      if (idle > 0) {
        final t = l % 1;
        canvas.drawCircle(
          day,
          7.5 * u + 9 * u * t,
          Paint()
            ..color = accent.withValues(alpha: idle * 0.5 * (1 - t))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6 * u,
        );
      }
    }

    // Yesterday's page, torn up over the rings: folding about the header's
    // edge, foreshortened, its back darker once it passes edge-on.
    if (flip < 1) {
      final fold = math.cos(flip * math.pi);
      final pageTop = card.top + head;
      final pageH = (h - head) * fold.abs();
      final rect = fold >= 0
          ? Rect.fromLTWH(card.left, pageTop, w, pageH)
          : Rect.fromLTWH(card.left, pageTop - pageH, w, pageH);
      canvas.save();
      canvas.clipRRect(
        fold >= 0 ? rr : RRect.fromRectAndRadius(rect, Radius.circular(9 * u)),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = fold >= 0 ? this.card : Color.lerp(this.card, accent, 0.6)!,
      );
      if (fold >= 0) {
        final lines = Paint()..color = accent.withValues(alpha: 0.18 * fold);
        for (var i = 0; i < 3; i++) {
          canvas.drawRect(
            Rect.fromLTWH(
              card.left + 10 * u,
              pageTop + pageH * (0.25 + 0.25 * i),
              w - 20 * u,
              2.4 * u * fold,
            ),
            lines,
          );
        }
      }
      canvas.restore();
    }

    // The binding rings, over everything.
    final ring = Paint()
      ..color = _lighten(accent, 0.4)
      ..strokeWidth = 3.4 * u
      ..strokeCap = StrokeCap.round;
    for (final dx in [-w * 0.26, w * 0.26]) {
      canvas.drawLine(
        Offset(c.dx + dx, card.top - 6 * u),
        Offset(c.dx + dx, card.top + 6 * u),
        ring,
      );
    }
    canvas.restore();
  }

  // ── alert ──

  void _alert(Canvas canvas, Offset c, double u, double a, double l) {
    final idle = _idle(a);
    final drop = _segRaw(a, 0, 0.28, Curves.easeOutBack);
    final rattle = _seg(a, 0.3, 0.52);
    final on = _seg(a, 0.36, 0.56);
    final first = _seg(a, 0.4, 1, AppMotion.easeOut);
    final dome = Offset(c.dx, c.dy + 14 * u);
    final r = 20 * u;

    // Ripples: one sent by the arrival, then the loop's.
    final ripple = Paint()..style = PaintingStyle.stroke;
    void ring(double t, double alpha) {
      if (alpha <= 0) return;
      ripple
        ..color = accent.withValues(alpha: (alpha * (1 - t)).clamp(0, 1))
        ..strokeWidth = (3 - 1.8 * t) * u;
      canvas.drawCircle(dome - Offset(0, 6 * u), r + 34 * u * t, ripple);
    }

    if (first > 0 && first < 1) ring(first, 0.9);
    ring(l, idle * 0.7);
    ring((l + 0.5) % 1, idle * 0.7);

    // The turning light: two beams, foreshortened as they swing round.
    if (on > 0) {
      final phase = l * 2 * math.pi;
      for (final side in const [0.0, math.pi]) {
        final reach = math.cos(phase + side);
        if (reach <= 0) continue;
        final dir = side == 0 ? 1.0 : -1.0;
        final length = 50 * u * reach * on;
        final origin = dome - Offset(0, 8 * u);
        final beam = Path()
          ..moveTo(origin.dx, origin.dy - 3 * u)
          ..lineTo(origin.dx + dir * length, origin.dy - 14 * u * reach)
          ..lineTo(origin.dx + dir * length, origin.dy + 10 * u * reach)
          ..lineTo(origin.dx, origin.dy + 3 * u)
          ..close();
        canvas.drawPath(
          beam,
          Paint()
            ..shader = ui.Gradient.linear(
              origin,
              origin + Offset(dir * math.max(1, length), 0),
              [
                accent.withValues(alpha: 0.55 * on),
                accent.withValues(alpha: 0),
              ],
            ),
        );
      }
    }

    canvas.save();
    canvas.translate(0, -60 * u * (1 - drop));
    canvas.translate(dome.dx, dome.dy + 14 * u);
    canvas.rotate(0.12 * math.sin(rattle * math.pi * 8) * (1 - rattle));
    canvas.translate(-dome.dx, -(dome.dy + 14 * u));

    _glow(
      canvas,
      dome - Offset(0, 6 * u),
      34 * u,
      on * (0.35 + idle * 0.15 * math.sin(l * 4 * math.pi)),
    );
    final domePath = Path()
      ..moveTo(dome.dx - r, dome.dy)
      ..arcToPoint(Offset(dome.dx + r, dome.dy), radius: Radius.circular(r))
      ..close();
    canvas.drawPath(
      domePath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(dome.dx, dome.dy - r),
          Offset(dome.dx, dome.dy),
          [
            Color.lerp(_darken(accent, 0.3), _lighten(accent, 0.3), on)!,
            Color.lerp(_darken(accent, 0.45), accent, on)!,
          ],
        ),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(dome.dx, dome.dy + 6 * u),
          width: 2 * r + 12 * u,
          height: 11 * u,
        ),
        Radius.circular(3.5 * u),
      ),
      Paint()..color = _lighten(accent, 0.12),
    );
    // "!" in the dome.
    final mark = Paint()
      ..color = onAccent.withValues(alpha: 0.9)
      ..strokeWidth = 3.4 * u
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(dome.dx, dome.dy - r * 0.72),
      Offset(dome.dx, dome.dy - r * 0.3),
      mark,
    );
    canvas.drawCircle(
      Offset(dome.dx, dome.dy - r * 0.1),
      1.9 * u,
      Paint()..color = mark.color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EmblemPainter old) =>
      old.category != category ||
      old.accent != accent ||
      old.card != card ||
      old.reduced != reduced ||
      old.arrival != arrival;
}

// ── Backdrop ────────────────────────────────────────────────────────────────

/// What fills the sheet behind an announcement, in its category's spirit:
/// confetti drifting down for a gift, dust twinkling for a feature, the
/// broadcast washing across for news, a warm glow for a tip, a faint grid of
/// days for an event, and a slow red pulse along the top for an alert.
///
/// Always faint — it is atmosphere, never something to read — and always
/// still under reduced motion.
class AnnouncementBackdrop extends StatefulWidget {
  const AnnouncementBackdrop({
    required this.category,
    required this.arrival,
    required this.centre,
    super.key,
  });

  final AnnouncementCategory category;
  final Animation<double> arrival;

  /// Where the emblem sits, for the effects that come out of it.
  final ValueListenable<Offset?> centre;

  @override
  State<AnnouncementBackdrop> createState() => _AnnouncementBackdropState();
}

class _AnnouncementBackdropState extends State<AnnouncementBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.4);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _BackdropPainter(
          category: widget.category,
          arrival: widget.arrival,
          loop: _loop,
          centre: widget.centre,
          accent: AnnouncementStyle.of(widget.category).accent,
          festive: AnnouncementStyle.festive(),
          reduced: AppMotion.reduced(context),
        ),
      ),
    ),
  );
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.category,
    required this.arrival,
    required this.loop,
    required this.centre,
    required this.accent,
    required this.festive,
    required this.reduced,
  }) : super(repaint: Listenable.merge([arrival, loop, centre]));

  final AnnouncementCategory category;
  final Animation<double> arrival;
  final Animation<double> loop;
  final ValueListenable<Offset?> centre;
  final Color accent;
  final List<Color> festive;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    final a = arrival.value;
    final l = loop.value;
    final c = centre.value ?? Offset(size.width / 2, 80);
    switch (category) {
      case AnnouncementCategory.gift:
        final weight = _seg(a, 0.6, 1);
        if (weight <= 0) return;
        for (var i = 0; i < 26; i++) {
          final x = _hash(i, 3) * size.width;
          final speed = 0.6 + 0.8 * _hash(i, 4);
          final t = (l * speed + _hash(i, 5)) % 1;
          final y = -12 + (size.height + 24) * t;
          final sway = math.sin(t * math.pi * 4 + i) * 10;
          canvas.save();
          canvas.translate(x + sway, y);
          canvas.rotate(t * math.pi * 6 * (i.isEven ? 1 : -1));
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-3, -1.5, 6, 3),
              const Radius.circular(1),
            ),
            Paint()
              ..color = festive[i % festive.length].withValues(
                alpha: 0.32 * weight,
              ),
          );
          canvas.restore();
        }
      case AnnouncementCategory.feature:
        final weight = _seg(a, 0.4, 1);
        if (weight <= 0) return;
        for (var i = 0; i < 18; i++) {
          final p = Offset(_hash(i, 6) * size.width, _hash(i, 7) * size.height);
          final s = math.pow(
            math.max(0, math.sin(l * 2 * math.pi * 3 + i * 1.7)),
            4,
          );
          if (s < 0.02) continue;
          canvas.drawPath(
            _sparkle(p, (2 + 3 * _hash(i, 8)) * (0.5 + 0.5 * s)),
            Paint()..color = accent.withValues(alpha: 0.4 * weight * s),
          );
        }
      case AnnouncementCategory.news:
        // The first broadcast washes across the whole sheet, once.
        final t = _seg(a, 0.46, 1);
        if (t <= 0 || t >= 1 || reduced) return;
        final far = (size.bottomRight(Offset.zero) - c).distance + 40;
        final paint = Paint()..style = PaintingStyle.stroke;
        for (var k = 0; k < 2; k++) {
          final tt = (t - k * 0.16).clamp(0.0, 1.0);
          if (tt <= 0) continue;
          paint
            ..color = accent.withValues(alpha: 0.22 * (1 - tt))
            ..strokeWidth = 2 + 6 * (1 - tt);
          canvas.drawCircle(c, far * AppMotion.easeOut.transform(tt), paint);
        }
      case AnnouncementCategory.tip:
        final weight = _flickerGlow(a);
        if (weight <= 0) return;
        final r = size.width * 0.7;
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = ui.Gradient.radial(c, r, [
              accent.withValues(
                alpha: weight * (0.13 + 0.03 * math.sin(l * 2 * math.pi * 3)),
              ),
              accent.withValues(alpha: 0),
            ]),
        );
      case AnnouncementCategory.event:
        final weight = _seg(a, 0.5, 1);
        if (weight <= 0) return;
        final paint = Paint()..color = accent.withValues(alpha: 0.07 * weight);
        const step = 26.0;
        for (var y = step; y < size.height; y += step) {
          for (var x = step / 2; x < size.width; x += step) {
            canvas.drawCircle(Offset(x, y), 1.3, paint);
          }
        }
      case AnnouncementCategory.alert:
        final weight = _seg(a, 0.36, 0.7);
        if (weight <= 0) return;
        final pulse = 0.5 + 0.5 * math.sin(l * 2 * math.pi * 5);
        final band = Rect.fromLTWH(0, 0, size.width, 120);
        canvas.drawRect(
          band,
          Paint()
            ..shader = ui.Gradient.linear(band.topCenter, band.bottomCenter, [
              accent.withValues(alpha: weight * (0.1 + 0.1 * pulse)),
              accent.withValues(alpha: 0),
            ]),
        );
    }
  }

  static double _flickerGlow(double a) => _EmblemPainter._flicker(a);

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.category != category ||
      old.accent != accent ||
      old.reduced != reduced ||
      old.arrival != arrival;
}

// ── Highlight ───────────────────────────────────────────────────────────────

/// "3 months free" on a perforated ticket, stamped onto the sheet: it comes
/// down large and tilted, lands with a little bounce, and a glint runs along
/// it once it is down.
class HighlightTicket extends StatelessWidget {
  const HighlightTicket({
    required this.text,
    required this.accent,
    required this.arrival,
    super.key,
  });

  final String text;
  final Color accent;

  /// 0 → 1 for this ticket's own stamp.
  final Animation<double> arrival;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final ticket = CustomPaint(
      painter: _TicketPainter(
        accent: accent,
        card: AppColors.card,
        shine: arrival,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 11),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accent,
            fontSize: 17,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
    if (reduced) return FadeTransition(opacity: arrival, child: ticket);
    return AnimatedBuilder(
      animation: arrival,
      builder: (context, child) {
        final t = arrival.value;
        final land = _segRaw(t, 0, 0.55, Curves.easeOutBack);
        final scale = ui.lerpDouble(1.7, 1, land)!;
        return Opacity(
          opacity: _seg(t, 0, 0.25),
          child: Transform.rotate(
            angle: ui.lerpDouble(
              -0.2,
              -0.035,
              _seg(t, 0, 0.55, AppMotion.easeOut),
            )!,
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: ticket,
    );
  }
}

class _TicketPainter extends CustomPainter {
  _TicketPainter({
    required this.accent,
    required this.card,
    required this.shine,
  }) : super(repaint: shine);

  final Color accent;
  final Color card;
  final Animation<double> shine;

  @override
  void paint(Canvas canvas, Size size) {
    const notch = 7.0;
    final rect = Offset.zero & size;
    final shape = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(10)));
    final bites = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(0, size.height / 2), radius: notch),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width, size.height / 2),
          radius: notch,
        ),
      );
    final ticket = Path.combine(PathOperation.difference, shape, bites);
    canvas.drawPath(ticket, Paint()..color = Color.lerp(card, accent, 0.12)!);
    canvas.drawPath(
      ticket,
      Paint()
        ..color = accent.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // The perforation, just inside each notch.
    final dash = Paint()
      ..color = accent.withValues(alpha: 0.45)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (final x in [notch + 6, size.width - notch - 6]) {
      for (var y = 5.0; y < size.height - 4; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, y + 2.5), dash);
      }
    }
    // One glint across it, after it lands.
    final t = _seg(shine.value, 0.55, 1);
    if (t > 0 && t < 1) {
      final band = size.width * 0.3;
      final x = -band + (size.width + 2 * band) * Curves.easeInOut.transform(t);
      canvas.save();
      canvas.clipPath(ticket);
      final r = Rect.fromLTWH(x - band, 0, band * 2, size.height);
      canvas.drawRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(
            r.centerLeft,
            r.centerRight,
            [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: 0.35),
              Colors.white.withValues(alpha: 0),
            ],
            const [0, 0.5, 1],
          ),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_TicketPainter old) =>
      old.accent != accent || old.card != card;
}
