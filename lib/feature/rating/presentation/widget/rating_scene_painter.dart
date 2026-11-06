import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/widget/animations/rider_cartoon.dart';

/// Everything one frame of the rating scene needs, as plain numbers.
///
/// The sheet owns the controllers and turns them into this; the painter only
/// draws, so the whole scene is one `CustomPaint` repainting from one
/// listenable (the same budget the report story keeps on the floor device).
@immutable
class RatingSceneFrame {
  const RatingSceneFrame({
    required this.youIn,
    required this.friendIn,
    required this.link,
    required this.wavePhase,
    required this.starBirth,
    required this.gather,
    required this.launch,
    required this.homecoming,
    required this.youHop,
    required this.friendHop,
    required this.mood,
    required this.ambient,
    required this.rtl,
    required this.youColor,
    required this.friendColor,
    required this.gold,
    required this.ink,
    required this.road,
    required this.sky,
    this.youImage,
    this.youInitial = '',
  });

  /// Entrance pop of each rider, 0 → 1 (may overshoot).
  final double youIn;
  final double friendIn;

  /// The radio link between the two helmets, 0 … 1.
  final double link;
  final double wavePhase;

  /// The five stars rising out of the link into their arc, 0 → 1. Each star
  /// takes its own slice, so they arrive one after another.
  final double starBirth;

  /// The stars flying together into one big star, 0 → 1 (may overshoot).
  final double gather;

  /// The big star shooting off toward Bazaar as a comet, 0 → 1.
  final double launch;

  /// Coming back from Bazaar: the star falls home and bursts into thanks,
  /// 0 → 1.
  final double homecoming;

  /// A tap's hop on each rider, 0 → 1 (a heart floats up with it).
  final double youHop;
  final double friendHop;

  /// Both riders' mood, -1 … 1.
  final double mood;

  /// The ambient loop: bob, blink, twinkle, the rolling road.
  final double ambient;

  /// You ride at the reading start, so the stage mirrors in Persian.
  final bool rtl;

  final Color youColor;
  final Color friendColor;
  final Color gold;
  final Color ink;
  final Color road;

  /// The tint of the faint background stars.
  final Color sky;

  final ui.Image? youImage;
  final String youInitial;
}

/// Two riders on the road, talking over Tarkk, and the stars their rides
/// earn.
///
/// The radio waves between the helmets throw off five stars that settle in
/// an arc above them and twinkle. Rating gathers the five into one big star
/// that shoots off as a comet, which is the app handing you over to Bazaar;
/// coming back brings the star home, bursting into thanks.
///
/// Drawn on a fixed 340 × 200 stage scaled to fit, with no clipping and no
/// blur: glows are stacked translucent strokes.
class RatingScenePainter extends CustomPainter {
  RatingScenePainter(this.frame);

  final RatingSceneFrame frame;

  static const stage = Size(340, 200);
  static const double _faceR = RiderCartoon.faceRadius;
  static const starCount = 5;

  /// Where the riders' faces are on the left-to-right stage, for hit tests.
  static const youAtLtr = Offset(96, 128);
  static const friendAtLtr = Offset(244, 124);

  /// Where the gathered star hangs before it flies.
  static const _heart = Offset(170, 46);

  double get _dir => frame.rtl ? -1 : 1;
  double _x(double x) => frame.rtl ? stage.width - x : x;
  Offset _p(Offset ltr) => Offset(_x(ltr.dx), ltr.dy);

  Offset get _youAt => _p(youAtLtr);
  Offset get _friendAt => _p(friendAtLtr);

  /// Maps a point in a [size]d canvas back onto the stage.
  static Offset toStage(Offset local, Size size) {
    final scale = math.min(
      size.width / stage.width,
      size.height / stage.height,
    );
    final dx = (size.width - stage.width * scale) / 2;
    final dy = (size.height - stage.height * scale) / 2;
    return Offset((local.dx - dx) / scale, (local.dy - dy) / scale);
  }

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

    _sky(canvas);
    _road(canvas);
    _waves(canvas);
    _rider(
      canvas,
      at: _friendAt,
      pop: frame.friendIn,
      color: frame.friendColor,
      look: -_dir,
      hop: frame.friendHop,
      phase: 1.3,
    );
    _rider(
      canvas,
      at: _youAt,
      pop: frame.youIn,
      color: frame.youColor,
      look: _dir,
      hop: frame.youHop,
      phase: 0,
      image: frame.youImage,
      initial: frame.youInitial,
    );
    _hearts(canvas);
    _stars(canvas);
    _comet(canvas);
    _homecoming(canvas);

    canvas.restore();
  }

  // ── Backdrop ─────────────────────────────────────────────────────────────

  /// Faint stars far away, each breathing on its own beat.
  void _sky(Canvas canvas) {
    final rng = math.Random(7);
    for (var i = 0; i < 18; i++) {
      final at = Offset(
        14 + rng.nextDouble() * (stage.width - 28),
        6 + rng.nextDouble() * 92,
      );
      final beat = math.sin(
        (frame.ambient * 2 + rng.nextDouble()) * math.pi * 2,
      );
      final alpha = (0.14 + 0.16 * beat) * frame.link;
      if (alpha <= 0.01) continue;
      canvas.drawCircle(
        _p(at),
        0.9 + rng.nextDouble() * 1.1,
        Paint()..color = frame.sky.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }
  }

  /// The road both of them are riding, dashes rolling under them.
  void _road(Canvas canvas) {
    const y = 176.0;
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

  // ── Riders ───────────────────────────────────────────────────────────────

  void _rider(
    Canvas canvas, {
    required Offset at,
    required double pop,
    required Color color,
    required double look,
    required double hop,
    required double phase,
    ui.Image? image,
    String initial = '',
  }) {
    if (pop <= 0) return;
    final happy = math.max(0.0, frame.mood);
    final beat = frame.ambient * math.pi * 4 + phase;
    // A beaming rider bounces with the music; a tap makes them jump.
    final bounce = happy > 0.7
        ? math.sin(beat).abs() * 7 * (happy - 0.7) / 0.3
        : 0.0;
    final jump = math.sin(math.pi * hop.clamp(0.0, 1.0)) * 16;
    final bob = math.sin(beat) * 2.2;
    final center = at + Offset(0, bob - bounce - jump);
    final landing = hop > 0.8 ? (hop - 0.8) / 0.2 : 0.0;
    _glow(canvas, center, color, frame.homecoming * (1 - frame.homecoming) * 4);
    RiderCartoon.face(
      canvas,
      center: center,
      pop: pop,
      color: color,
      mood: frame.mood,
      anger: 0,
      lookToward: look,
      squash:
          math.sin(math.pi * landing) * 0.8 +
          (bounce > 0 ? (1 - bounce / 7) * 0.4 : 0),
      talking: 0,
      tear: 0,
      tilt: look * 0.06 * math.sin(beat * 0.5),
      ink: frame.ink,
      ambient: frame.ambient,
    );
    if (image != null || initial.isNotEmpty) {
      RiderCartoon.sticker(
        canvas,
        center: center,
        pop: pop,
        side: -look,
        image: image,
        initial: initial,
        tint: color,
        wobble: hop > 0 ? 1 - hop : 0,
        ambient: frame.ambient,
      );
    }
  }

  void _glow(Canvas canvas, Offset center, Color color, double glow) {
    if (glow < 0.01) return;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        center,
        _faceR + 6 + i * 5.0,
        Paint()
          ..color = color.withValues(
            alpha: 0.22 * glow.clamp(0.0, 1.0) / (i + 1),
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  }

  /// A heart floating up from whoever was tapped.
  void _hearts(Canvas canvas) {
    for (final (at, t) in [
      (_youAt, frame.youHop),
      (_friendAt, frame.friendHop),
    ]) {
      if (t <= 0 || t >= 1) continue;
      final rise = Curves.easeOut.transform(t);
      final center =
          at + Offset(math.sin(t * math.pi * 3) * 6, -_faceR - 18 - 34 * rise);
      final size = 10 * Curves.easeOutBack.transform((t / 0.3).clamp(0.0, 1.0));
      _heartShape(
        canvas,
        center,
        size,
        const Color(
          0xFFFF6B8A,
        ).withValues(alpha: (1 - t) * 1.4 > 1 ? 1 : (1 - t) * 1.4),
      );
    }
  }

  void _heartShape(Canvas canvas, Offset c, double s, Color color) {
    if (s <= 0) return;
    final path = Path()
      ..moveTo(c.dx, c.dy + s)
      ..cubicTo(
        c.dx - s * 1.6,
        c.dy - s * 0.2,
        c.dx - s * 0.7,
        c.dy - s * 1.4,
        c.dx,
        c.dy - s * 0.5,
      )
      ..cubicTo(
        c.dx + s * 0.7,
        c.dy - s * 1.4,
        c.dx + s * 1.6,
        c.dy - s * 0.2,
        c.dx,
        c.dy + s,
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  // ── The link ─────────────────────────────────────────────────────────────

  /// Soft, round radio arcs travelling both ways between the helmets: the
  /// conversation Tarkk carries. Friendly where the report's waves sting.
  Offset get _youMouth => _youAt + Offset(_dir * (_faceR + 6), -4);
  Offset get _friendMouth => _friendAt + Offset(-_dir * (_faceR + 6), -6);

  void _waves(Canvas canvas) {
    final strength = frame.link * (1 - frame.launch * 0.6);
    if (strength <= 0.01) return;
    for (var lane = 0; lane < 2; lane++) {
      final from = lane == 0 ? _youMouth : _friendMouth;
      final to = lane == 0 ? _friendMouth : _youMouth;
      final color = lane == 0 ? frame.youColor : frame.friendColor;
      final toward = lane == 0 ? _dir : -_dir;
      for (var i = 0; i < 2; i++) {
        final p = (frame.wavePhase + i / 2 + lane * 0.25) % 1;
        final at = Offset.lerp(from, to, p)!;
        final alpha = (math.sin(p * math.pi) * strength).clamp(0.0, 1.0);
        if (alpha <= 0.02) continue;
        final h = 12 + 10 * math.sin(p * math.pi);
        final rect = Rect.fromCenter(
          center: at + Offset(-toward * h * 0.4, lane == 0 ? -6 : 6),
          width: h,
          height: h * 1.6,
        );
        canvas.drawArc(
          rect,
          toward > 0 ? -0.9 : math.pi - 0.9,
          1.8,
          false,
          Paint()
            ..color = color.withValues(alpha: alpha * 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      }
    }
  }

  // ── The stars ────────────────────────────────────────────────────────────

  /// The arc slot of star [i]: a gentle rainbow over the riders.
  Offset _slot(int i) {
    final t = i / (starCount - 1);
    final x = 92 + 156 * t;
    final y = 60 - 30 * math.sin(math.pi * t);
    return _p(Offset(x, y));
  }

  Offset get _birthplace => _p(const Offset(170, 112));

  Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  void _stars(Canvas canvas) {
    final birth = frame.starBirth;
    if (birth <= 0) return;
    final gather = frame.gather;
    // Once the comet is away the arc is empty until it comes home.
    final gone = frame.launch > 0 && frame.homecoming <= 0;
    if (gone && gather >= 1) return;
    for (var i = 0; i < starCount; i++) {
      // Each star's own slice of the birth, centre-out so the arc fills
      // symmetrically: 2, then 1 and 3, then 0 and 4.
      final order = (i - 2).abs();
      final local = ((birth - order * 0.16) / 0.52).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final rise = Curves.easeOutCubic.transform(local);
      final slot = _slot(i);
      final control = Offset(
        (_birthplace.dx + slot.dx) / 2 + (i - 2) * 18.0,
        slot.dy - 26,
      );
      var at = _quad(_birthplace, control, slot, rise);
      final pop = Curves.elasticOut.transform(local);
      // The twinkle: each star breathes on its own beat, and a shine sweeps
      // across the arc once per loop.
      final beat = math.sin((frame.ambient * 2 + i * 0.2) * math.pi * 2);
      final sweep = math.exp(
        -math.pow(((frame.ambient * 1.6) % 1.6 - 0.2 - i * 0.16) * 7, 2),
      );
      var r = 11.5 * pop * (1 + 0.06 * beat + 0.14 * sweep);
      var spin = (1 - rise) * math.pi * 1.2 * (i.isEven ? 1 : -1) + 0.08 * beat;
      if (gather > 0) {
        final g = gather.clamp(0.0, 1.0);
        final pull = Curves.easeInCubic.transform(g);
        final swirl = Offset(
          math.cos(i * 1.256 + g * 4) * 22 * (1 - g),
          math.sin(i * 1.256 + g * 4) * 14 * (1 - g),
        );
        at = Offset.lerp(at, _p(_heart), pull)! + swirl * g;
        r *= 1 - 0.55 * pull;
        spin += g * math.pi * 2;
        if (g >= 0.98) continue;
      }
      _starShape(canvas, at, r, spin, glint: sweep);
    }
    if (gather > 0.85 && frame.launch <= 0) {
      final grow = ((gather - 0.85) / 0.15).clamp(0.0, 1.3);
      _bigStar(canvas, _p(_heart), 22 * grow);
    }
  }

  /// A five-point star with a lit face and a stacked-stroke glow.
  void _starShape(
    Canvas canvas,
    Offset at,
    double r,
    double spin, {
    double glint = 0,
    double alpha = 1,
  }) {
    if (r <= 0.2) return;
    final path = _fivePoint(at, r, spin);
    final gold = frame.gold;
    for (var i = 0; i < 2; i++) {
      canvas.drawPath(
        path,
        Paint()
          ..color = gold.withValues(
            alpha: (0.18 + 0.2 * glint) / (i + 1) * alpha,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5.0 + i * 5
          ..strokeJoin = StrokeJoin.round,
      );
    }
    final bounds = Rect.fromCircle(center: at, radius: r);
    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(bounds.topLeft, bounds.bottomRight, [
          Color.lerp(
            gold,
            Colors.white,
            0.45 + 0.3 * glint,
          )!.withValues(alpha: alpha),
          Color.lerp(
            gold,
            const Color(0xFFE07A00),
            0.35,
          )!.withValues(alpha: alpha),
        ]),
    );
    // A tiny white catchlight on the upper arm.
    canvas.drawCircle(
      at + Offset(-r * 0.22, -r * 0.3),
      r * 0.14,
      Paint()
        ..color = Colors.white.withValues(alpha: (0.6 + 0.4 * glint) * alpha),
    );
  }

  Path _fivePoint(Offset c, double r, double spin) {
    final path = Path();
    for (var k = 0; k < 10; k++) {
      final a = -math.pi / 2 + spin + k * math.pi / 5;
      final len = k.isEven ? r : r * 0.48;
      final p = c + Offset(math.cos(a) * len, math.sin(a) * len);
      if (k == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  /// The gathered star: bigger, brighter, with rays turning around it.
  void _bigStar(Canvas canvas, Offset at, double r, {double alpha = 1}) {
    if (r <= 0.5) return;
    final turn = frame.ambient * math.pi * 2;
    for (var i = 0; i < 8; i++) {
      final a = turn * 0.25 + i * math.pi / 4;
      final inner = r * 1.25;
      final outer = r * (1.7 + 0.25 * math.sin(turn * 2 + i));
      canvas.drawLine(
        at + Offset(math.cos(a) * inner, math.sin(a) * inner),
        at + Offset(math.cos(a) * outer, math.sin(a) * outer),
        Paint()
          ..color = frame.gold.withValues(alpha: 0.5 * alpha)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
    }
    _starShape(canvas, at, r, 0.05 * math.sin(turn), glint: 0.6, alpha: alpha);
  }

  // ── Off to Bazaar ────────────────────────────────────────────────────────

  /// Where the comet is at [t] of its flight: a beat of wind-up, then a fast
  /// arc out over the reading-end top corner.
  Offset _cometAt(double t) {
    final start = _p(_heart);
    final windUp = _p(const Offset(162, 58));
    final peak = _p(const Offset(250, -10));
    final exit = _p(const Offset(380, -70));
    if (t < 0.2) {
      return Offset.lerp(start, windUp, Curves.easeOut.transform(t / 0.2))!;
    }
    final f = Curves.easeInCubic.transform((t - 0.2) / 0.8);
    return _quad(windUp, peak, exit, f);
  }

  void _comet(Canvas canvas) {
    final t = frame.launch;
    if (t <= 0 || t >= 1 || frame.homecoming > 0) return;
    // The tail: the same star a moment ago, fading and shrinking.
    for (var k = 9; k >= 1; k--) {
      final past = t - k * 0.022;
      if (past <= 0.2) continue;
      final fade = 1 - k / 10;
      canvas.drawCircle(
        _cometAt(past),
        2 + 9 * fade,
        Paint()..color = frame.gold.withValues(alpha: 0.32 * fade),
      );
    }
    final squeeze = t < 0.2 ? 1 - 0.18 * math.sin(math.pi * t / 0.2) : 1.0;
    _bigStar(canvas, _cometAt(t), 22 * squeeze * (1 - 0.35 * t));
  }

  // ── Back home ────────────────────────────────────────────────────────────

  void _homecoming(Canvas canvas) {
    final h = frame.homecoming;
    if (h <= 0) return;
    final home = _p(_heart);
    // 0 … 0.35: the star drops back in from the top.
    if (h < 0.35) {
      final f = Curves.easeOutBack.transform(h / 0.35);
      final at = Offset.lerp(_p(const Offset(170, -40)), home, f)!;
      for (var k = 1; k <= 6; k++) {
        canvas.drawCircle(
          at + Offset(0, -k * 7.0),
          6 - k * 0.8,
          Paint()..color = frame.gold.withValues(alpha: 0.28 * (1 - k / 7)),
        );
      }
      _bigStar(canvas, at, 22);
      return;
    }
    // 0.35 … 1: it bursts into confetti and hearts while the arc re-forms.
    final b = (h - 0.35) / 0.65;
    final pop = 1 - Curves.easeOut.transform((b / 0.25).clamp(0.0, 1.0));
    _bigStar(canvas, home, 22 * (1 + 0.4 * (1 - pop)) * pop, alpha: pop);
    const colors = [
      Color(0xFFFFC53D),
      Color(0xFF7FD3FF),
      Color(0xFFFF6B8A),
      Color(0xFF7EE787),
    ];
    final spread = Curves.easeOutCubic.transform(b);
    final fade = (1 - b).clamp(0.0, 1.0);
    for (var i = 0; i < 16; i++) {
      final a = i * math.pi * 2 / 16 + 0.2;
      final dist = 14 + 96 * spread * (0.7 + 0.3 * ((i * 7) % 5) / 4);
      final gravity = 40 * b * b;
      final at =
          home +
          Offset(math.cos(a) * dist, math.sin(a) * dist * 0.75 + gravity);
      final color = colors[i % 4].withValues(alpha: fade);
      if (i % 4 == 2) {
        _heartShape(canvas, at, 5 * (1 - 0.3 * b), color);
      } else {
        RiderCartoon.sparkle(
          canvas,
          at,
          (2.6 + (i % 3)) * (1 - 0.4 * b),
          color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(RatingScenePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
