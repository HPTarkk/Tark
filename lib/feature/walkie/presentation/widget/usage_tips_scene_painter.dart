import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../../core/widget/animations/rider_cartoon.dart';

/// The four tips, in the order the sheet tells them.
enum UsageTip { headset, helmet, handsFree, widget }

/// Everything one frame of the tips scene needs, as plain numbers.
///
/// The sheet owns the controllers and turns them into this; the painter only
/// draws, so the whole scene is one `CustomPaint` repainting from one
/// listenable (see `AppMotion` on the floor device).
@immutable
class UsageTipsFrame {
  const UsageTipsFrame({
    required this.youIn,
    required this.page,
    required this.tip,
    required this.arrive,
    required this.hop,
    required this.ambient,
    required this.rtl,
    required this.youColor,
    required this.friendColor,
    required this.ink,
    required this.paper,
    required this.road,
    required this.danger,
    this.youImage,
    this.youInitial = '',
  });

  /// The rider's entrance pop, 0 → 1 (may overshoot).
  final double youIn;

  /// The carousel's position, continuous: 1.5 is halfway from the second
  /// tip to the third. Every prop fades with its distance from here, so a
  /// swipe crossfades the scene under the finger.
  final double page;

  /// The tip the carousel last settled on, and how far its little act has
  /// played, 0 → 1. Every other tip waits in its "about to happen" pose.
  final int tip;
  final double arrive;

  /// A tap on the scene, 0 → 1 (0 = none): the rider jumps.
  final double hop;

  /// The ambient loop: bob, blink, the road rolling, noise in the wind.
  final double ambient;

  /// You ride at the reading start, so in Persian the stage is mirrored.
  /// Only positions mirror; nothing is drawn backwards.
  final bool rtl;

  final Color youColor;
  final Color friendColor;
  final Color ink;
  final Color paper;
  final Color road;
  final Color danger;
  final ui.Image? youImage;
  final String youInitial;

  /// How present tip [i]'s props are: 1 when the carousel rests on it,
  /// fading to 0 one page away.
  double presence(int i) => (1 - (page - i).abs()).clamp(0.0, 1.0);

  /// How far tip [i]'s act has played.
  double progress(int i) => i == tip ? arrive : 0;

  @override
  bool operator ==(Object other) =>
      other is UsageTipsFrame &&
      other.youIn == youIn &&
      other.page == page &&
      other.tip == tip &&
      other.arrive == arrive &&
      other.hop == hop &&
      other.ambient == ambient &&
      other.rtl == rtl &&
      other.youColor == youColor &&
      other.friendColor == friendColor &&
      other.ink == ink &&
      other.paper == paper &&
      other.road == road &&
      other.danger == danger &&
      other.youImage == youImage &&
      other.youInitial == youInitial;

  @override
  int get hashCode => Object.hash(
    youIn,
    page,
    tip,
    arrive,
    hop,
    ambient,
    rtl,
    youColor,
    friendColor,
    ink,
    paper,
    road,
    danger,
    youImage,
    youInitial,
  );
}

/// You, on the road, and the one thing each tip changes about your ride.
///
/// * **Headset**: wind and engine noise blow at you and you wince. A headset
///   drops onto your helmet with a spring, and the noise flattens out and
///   dissolves before it reaches your ears while the channel comes through.
/// * **Helmet**: a proper helmet drops on, its visor slides down, the strap
///   clicks shut, and a shield badge pops up beside you.
/// * **Hands-free**: a friend rides up. A push-to-talk button appears over
///   you, gets struck out and pops, and you just talk: your voice carries to
///   them while the noise around you is swept away.
/// * **Widget**: a phone rises with Tarkk's widget on its home screen,
///   showing who is on air. A tap on it, and you are on the road again.
///
/// Drawn on a fixed 340 × 200 stage scaled to fit, the same stage and the
/// same cartoon rider as the report and rating stories. No clipping and no
/// blur anywhere.
class UsageTipsScenePainter extends CustomPainter {
  UsageTipsScenePainter(this.frame);

  final UsageTipsFrame frame;

  static const stage = Size(340, 200);
  static const double _faceR = RiderCartoon.faceRadius;

  /// Where you ride on the left-to-right stage, for hit tests.
  static const youAtLtr = Offset(100, 122);
  static const double _roadY = 174;

  double get _dir => frame.rtl ? -1 : 1;
  double _x(double x) => frame.rtl ? stage.width - x : x;
  Offset _p(Offset ltr) => Offset(_x(ltr.dx), ltr.dy);

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

  static double _iv(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  /// A dropped thing landing: races in, overshoots its rest a little, bounces
  /// once and settles. 0 → 1, peaking near 1.13.
  static double _drop(double t) =>
      t <= 0 ? 0 : 1 - math.exp(-6 * t) * math.cos(9.5 * t);

  static double _ease(double t) => Curves.easeOutCubic.transform(t);
  static double _back(double t) => Curves.easeOutBack.transform(t);

  // Each tip's act, as named moments of its 0 → 1 progress.
  double get _headsetDrop => _iv(frame.progress(0), 0, 0.55);
  double get _helmetDrop => _iv(frame.progress(1), 0, 0.5);
  double get _visor => _iv(frame.progress(1), 0.42, 0.62);
  double get _buckle => _iv(frame.progress(1), 0.6, 0.85);
  double get _badge => _iv(frame.progress(1), 0.68, 0.95);
  double get _friendIn => _iv(frame.progress(2), 0, 0.3);
  double get _button => _iv(frame.progress(2), 0.2, 0.34);
  double get _press => _iv(frame.progress(2), 0.34, 0.46);
  double get _strike => _iv(frame.progress(2), 0.46, 0.56);
  double get _poof => _iv(frame.progress(2), 0.58, 0.7);
  double get _speak => _iv(frame.progress(2), 0.66, 0.8);
  double get _phoneRise => _iv(frame.progress(3), 0, 0.5);
  double get _card => _iv(frame.progress(3), 0.32, 0.52);
  double get _faces => _iv(frame.progress(3), 0.46, 0.66);
  double get _tap => _iv(frame.progress(3), 0.68, 0.84);
  double get _trail => _iv(frame.progress(3), 0.78, 0.94);
  double get _homeHop => _iv(frame.progress(3), 0.84, 1);

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
    _noise(canvas);
    _phone(canvas);
    _friend(canvas);
    _voice(canvas);
    _you(canvas);
    _pushToTalk(canvas);
    _shieldBadge(canvas);
    _sparkles(canvas);

    canvas.restore();
  }

  // ── Backdrop ─────────────────────────────────────────────────────────────

  /// The road, its dashes rolling under you. Swiping to the next tip rolls
  /// it further on: each tip is a little further down the same ride.
  void _road(Canvas canvas) {
    final paint = Paint()
      ..color = frame.road
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const dash = 16.0;
    const gap = 14.0;
    final shift =
        (frame.ambient * (dash + gap) * 2 + frame.page * (dash + gap) * 1.5) %
        (dash + gap);
    for (var x = 18.0 - shift; x < stage.width - 18; x += dash + gap) {
      final a = math.max(18.0, x);
      final b = math.min(stage.width - 18, x + dash);
      if (b > a) {
        canvas.drawLine(Offset(_x(a), _roadY), Offset(_x(b), _roadY), paint);
      }
    }
  }

  // ── You ──────────────────────────────────────────────────────────────────

  /// How you feel, blended across the tips by how present each one is.
  double get _mood {
    final moods = [
      // Wincing in the wind, then at ease once the headset is on.
      -0.4 + 1.25 * _ease(_iv(frame.progress(0), 0.25, 0.75)),
      0.1 + 0.6 * _ease(_iv(frame.progress(1), 0.55, 0.95)),
      0.25 + 0.6 * _ease(_iv(frame.progress(2), 0.66, 0.95)),
      0.2 + 0.8 * _ease(_iv(frame.progress(3), 0.8, 1)),
    ];
    var mood = 0.0;
    var weight = 0.0;
    for (var i = 0; i < moods.length; i++) {
      final w = frame.presence(i);
      mood += moods[i] * w;
      weight += w;
    }
    return weight == 0 ? 0.3 : mood / weight;
  }

  /// Where your face is this frame, bobbing, jumping on a tap and when the
  /// widget sends you riding.
  Offset get _youCenter {
    final beat = frame.ambient * math.pi * 4;
    final bob = math.sin(beat) * 2.2;
    final tapJump = math.sin(math.pi * frame.hop.clamp(0.0, 1.0)) * 18;
    final homeJump =
        math.sin(math.pi * _homeHop) *
        14 *
        frame.presence(UsageTip.widget.index);
    // Pushed back a touch while the wind is hitting you.
    final windPush =
        math.sin(frame.ambient * math.pi * 10) *
        1.4 *
        _unshielded *
        frame.presence(0);
    return _p(youAtLtr) + Offset(-_dir * windPush, bob - tapJump - homeJump);
  }

  /// How hard the noise is getting through to you, 0 … 1.
  double get _unshielded => 1 - _iv(frame.progress(0), 0.12, 0.4);

  void _you(Canvas canvas) {
    final pop = frame.youIn;
    if (pop <= 0) return;
    final center = _youCenter;
    final hop = frame.hop;
    final landing = hop > 0.8 ? (hop - 0.8) / 0.2 : 0.0;
    // Squash where something lands on your head, and when you land a jump.
    final headsetLand = _landSquash(_headsetDrop) * frame.presence(0);
    final helmetLand = _landSquash(_helmetDrop) * frame.presence(1);
    final squash = math.sin(math.pi * landing) * 0.8 + headsetLand + helmetLand;
    final mood = _mood;
    _glow(canvas, center, math.max(0.0, mood - 0.55) / 0.45);
    RiderCartoon.face(
      canvas,
      center: center,
      pop: pop,
      color: frame.youColor,
      mood: mood,
      anger: 0,
      lookToward: _dir,
      squash: squash,
      talking: _speak * frame.presence(2) * 0.75,
      tear: 0,
      tilt: -_dir * 0.08 * _unshielded * frame.presence(0),
      ink: frame.ink,
      ambient: frame.ambient,
    );
    _helmet(canvas, center, pop);
    _headset(canvas, center, pop);
    RiderCartoon.sticker(
      canvas,
      center: center,
      pop: pop,
      side: -_dir,
      image: frame.youImage,
      initial: frame.youInitial,
      tint: frame.youColor,
      wobble: (hop > 0 ? 1 - hop : 0) + headsetLand + helmetLand,
      ambient: frame.ambient,
    );
  }

  /// The squash a landing [drop] puts on the head under it: only while the
  /// spring is past its rest, pushing down.
  double _landSquash(double drop) {
    if (drop <= 0 || drop >= 1) return 0;
    final over = _drop(drop) - 1;
    return over > 0 ? over * 5 : 0;
  }

  void _glow(Canvas canvas, Offset center, double glow) {
    if (glow < 0.01) return;
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        center,
        _faceR + 8 + i * 5.0,
        Paint()
          ..color = frame.youColor.withValues(
            alpha: 0.18 * glow.clamp(0.0, 1.0) / (i + 1),
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
  }

  // ── Tip 1: the headset ───────────────────────────────────────────────────

  /// A band over the crown and two amber-rimmed cups over your ears. Waits
  /// hovering above you, then drops on.
  void _headset(Canvas canvas, Offset center, double pop) {
    final presence = frame.presence(0);
    if (presence <= 0.01) return;
    final drop = _drop(_headsetDrop);
    // Leaving, it lifts away the way it came.
    final hover = -70.0 * (1 - drop) - 18 * (1 - presence);
    final alpha = presence * (0.35 + 0.65 * _iv(drop, 0, 0.4));
    canvas.save();
    canvas.translate(center.dx, center.dy + hover);
    canvas.scale(pop);
    // The band: a grey arc with an ink outline, so it reads on any sheet.
    const steel = Color(0xFF66727F);
    final arc = Rect.fromCircle(center: Offset.zero, radius: _faceR + 8);
    for (final (width, color) in [(9.0, frame.ink), (5.0, steel)]) {
      canvas.drawArc(
        arc,
        math.pi + 0.16,
        math.pi - 0.32,
        false,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawArc(
      arc,
      math.pi + 0.75,
      math.pi - 1.5,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
    for (final side in const [-1.0, 1.0]) {
      final cup = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(side * (_faceR + 5), 0),
          width: 19,
          height: 32,
        ),
        const Radius.circular(9.5),
      );
      canvas.drawRRect(
        cup,
        Paint()
          ..shader = ui.Gradient.linear(
            cup.outerRect.topCenter,
            cup.outerRect.bottomCenter,
            [
              const Color(0xFF7D8995).withValues(alpha: alpha),
              const Color(0xFF3E4751).withValues(alpha: alpha),
            ],
          ),
      );
      canvas.drawRRect(
        cup,
        Paint()
          ..color = frame.ink.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      // The amber pad facing out, with a little light on it.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(side * (_faceR + 7), 0),
            width: 7,
            height: 18,
          ),
          const Radius.circular(3.5),
        ),
        Paint()..color = frame.youColor.withValues(alpha: alpha),
      );
    }
    canvas.restore();

    // Settled: a calm ring breathes around the forward cup, and the channel
    // comes through it in soft amber arcs.
    final shielded = (1 - _unshielded) * presence;
    if (shielded <= 0.01) return;
    final cup = center + Offset(_dir * (_faceR + 7), hover);
    for (var i = 0; i < 2; i++) {
      final p = (frame.ambient * 2 + i * 0.5) % 1;
      canvas.drawCircle(
        cup,
        16 + p * 14,
        Paint()
          ..color = frame.youColor.withValues(alpha: 0.4 * (1 - p) * shielded)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
  }

  /// Wind gusts and engine rattle blowing at you from the road ahead. With
  /// the headset on, each one flattens and dissolves before your ear.
  void _noise(Canvas canvas) {
    final presence = frame.presence(0);
    if (presence <= 0.01 || frame.youIn <= 0) return;
    final shield = 1 - _unshielded;
    final ear = _youCenter + Offset(_dir * (_faceR + 12), 0);
    final from = _p(const Offset(300, 0));
    for (var i = 0; i < 4; i++) {
      final p = (frame.ambient * 1.5 + i / 4) % 1;
      final y = ear.dy - 30 + i * 18.0 + math.sin(p * 5 + i) * 4;
      final start = Offset(from.dx, y);
      final end = Offset(ear.dx + _dir * (10 + 24 * shield), y);
      final at = Offset.lerp(start, end, p)!;
      // Flattens as it nears the cup once you are shielded.
      final calm = shield * _iv(p, 0.35, 0.85);
      final alpha = math.sin(p * math.pi) * presence * (1 - 0.85 * calm) * 0.9;
      if (alpha <= 0.02) continue;
      final paint = Paint()
        ..color = const Color(0xFF8E9AA6).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      const steps = 7;
      final len = 26.0;
      final amp = (i.isEven ? 5.0 : 3.6) * (1 - calm);
      for (var k = 0; k <= steps; k++) {
        final t = k / steps;
        final x = at.dx + _dir * len * t;
        // Even rows gust in curls, odd rows rattle like an engine.
        final wobble = i.isEven
            ? math.sin(t * math.pi * 2 + frame.ambient * math.pi * 6) * amp
            : (k.isOdd ? amp : -amp);
        k == 0
            ? path.moveTo(x, at.dy + wobble)
            : path.lineTo(x, at.dy + wobble);
      }
      canvas.drawPath(path, paint);
      // The end of a calmed gust breaks into a puff.
      if (calm > 0.6) {
        canvas.drawCircle(
          at,
          2 + 3 * (calm - 0.6) / 0.4,
          Paint()
            ..color = const Color(
              0xFFB8C2CC,
            ).withValues(alpha: 0.5 * presence * (1 - calm)),
        );
      }
    }
  }

  // ── Tip 2: the helmet ────────────────────────────────────────────────────

  /// A full shell hugging your head, a tinted visor that slides down, and a
  /// chin strap that clicks shut.
  void _helmet(Canvas canvas, Offset center, double pop) {
    final presence = frame.presence(1);
    if (presence <= 0.01) return;
    final t = _helmetDrop;
    final drop = _drop(t);
    final hover = -78.0 * (1 - drop) - 18 * (1 - presence);
    final spin = -_dir * 0.35 * (1 - _ease(t));
    final alpha = presence * (0.35 + 0.65 * _iv(drop, 0, 0.4));
    const r = _faceR;
    canvas.save();
    canvas.translate(center.dx, center.dy + hover);
    canvas.rotate(spin);
    canvas.scale(pop);

    const shellColor = Color(0xFFF2F4F7);
    final outer = Rect.fromCircle(center: Offset.zero, radius: r + 8);
    final inner = Rect.fromCircle(
      center: const Offset(0, r * 0.2),
      radius: r - 3,
    );
    const from = math.pi - 0.32;
    const sweep = math.pi + 0.64;
    final shell = Path()
      ..arcTo(outer, from, sweep, true)
      ..arcTo(inner, from + sweep, -sweep, false)
      ..close();
    canvas.drawPath(
      shell,
      Paint()
        ..shader = ui.Gradient.linear(outer.topLeft, outer.bottomRight, [
          shellColor.withValues(alpha: alpha),
          const Color(0xFFB9C2CC).withValues(alpha: alpha),
        ]),
    );
    canvas.drawPath(
      shell,
      Paint()
        ..color = frame.ink.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round,
    );
    // A racing stripe over the crown, in your colour.
    canvas.drawArc(
      Rect.fromCircle(center: Offset.zero, radius: r + 3.5),
      math.pi * 1.5 - 0.18,
      0.36,
      false,
      Paint()
        ..color = frame.youColor.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );

    // The visor: up on the shell while it lands, then slides down over the
    // eyes. Tinted, not opaque: your face still reads through it.
    final v = _ease(_visor);
    final visorY = -r * 0.62 + v * r * 0.56;
    final visor = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(_dir * 2, visorY),
        width: r * 1.62,
        height: 19,
      ),
      const Radius.circular(9.5),
    );
    canvas.drawRRect(
      visor,
      Paint()
        ..color = const Color(
          0xFF5BB8F0,
        ).withValues(alpha: alpha * (0.28 + 0.1 * v)),
    );
    canvas.drawRRect(
      visor,
      Paint()
        ..color = frame.ink.withValues(alpha: alpha * 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // A glint sweeps the visor as it settles.
    if (_visor > 0 && _visor < 1) {
      final gx = visor.left + visor.width * _visor;
      canvas.drawLine(
        Offset(gx - 4, visor.top + 3),
        Offset(gx + 3, visor.bottom - 3),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.8 * alpha)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    // The strap swings in under the chin and clicks.
    final b = _buckle;
    if (b > 0) {
      final strap = Paint()
        ..color = frame.ink.withValues(alpha: alpha * _iv(b, 0, 0.3))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      final close = _ease(_iv(b, 0, 0.5));
      final chin = Offset(0, r + 4);
      for (final side in const [-1.0, 1.0]) {
        // Hugging the jaw, from the shell's edge round under the chin.
        final top = Offset(side * (r + 4), r * 0.32);
        final swing = Offset.lerp(top + Offset(side * 8, 16), chin, close)!;
        canvas.drawPath(
          Path()
            ..moveTo(top.dx, top.dy)
            ..quadraticBezierTo(side * r * 0.86, r * 0.98, swing.dx, swing.dy),
          strap,
        );
      }
      if (close >= 1) {
        canvas.drawCircle(
          chin,
          3.6,
          Paint()..color = frame.youColor.withValues(alpha: alpha),
        );
      }
      // The click: a quick yellow pop at the buckle.
      final click = _iv(b, 0.45, 0.85);
      if (click > 0 && click < 1) {
        RiderCartoon.sparkle(
          canvas,
          chin + const Offset(0, 2),
          4 + 5 * math.sin(math.pi * click),
          const Color(0xFFFFC53D).withValues(alpha: alpha * (1 - click)),
        );
      }
    }
    canvas.restore();
  }

  /// A shield with a check, popping up beside you once the helmet is done.
  void _shieldBadge(Canvas canvas) {
    final presence = frame.presence(1);
    final t = _badge;
    if (presence <= 0.01 || t <= 0) return;
    final s = _back(t) * presence;
    final at =
        _youCenter +
        Offset(_dir * (_faceR + 34), -_faceR + 4) +
        Offset(0, math.sin(frame.ambient * math.pi * 4 + 1) * 2);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(_dir * 0.12 * (1 - t));
    canvas.scale(s);
    final shield = Path()
      ..moveTo(0, -17)
      ..quadraticBezierTo(9, -12, 15, -12)
      ..quadraticBezierTo(16, 8, 0, 17)
      ..quadraticBezierTo(-16, 8, -15, -12)
      ..quadraticBezierTo(-9, -12, 0, -17)
      ..close();
    canvas.drawPath(shield, Paint()..color = const Color(0xFF3FB950));
    canvas.drawPath(
      shield,
      Paint()
        ..color = frame.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round,
    );
    // The check draws itself in.
    final draw = _iv(t, 0.35, 1);
    if (draw > 0) {
      final a = const Offset(-6.5, 0);
      final m = const Offset(-1.5, 5.5);
      final e = const Offset(7, -5.5);
      final check = Path()..moveTo(a.dx, a.dy);
      if (draw < 0.4) {
        final p = Offset.lerp(a, m, draw / 0.4)!;
        check.lineTo(p.dx, p.dy);
      } else {
        check.lineTo(m.dx, m.dy);
        final p = Offset.lerp(m, e, (draw - 0.4) / 0.6)!;
        check.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        check,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
  }

  // ── Tip 3: hands-free ────────────────────────────────────────────────────

  static const _friendAtLtr = Offset(256, 120);

  Offset get _friendCenter {
    final presence = frame.presence(2);
    final enter = _back(_friendIn);
    // Waits just past the edge of the road, peeking in as you swipe over.
    final x = 372 - (372 - _friendAtLtr.dx) * enter + 40 * (1 - presence);
    final bob = math.sin(frame.ambient * math.pi * 4 + 1.3) * 2.2;
    // Nods along once your voice reaches them.
    final nod = math.sin(frame.ambient * math.pi * 8).abs() * 3 * _speak;
    return _p(Offset(x, _friendAtLtr.dy + bob + nod));
  }

  void _friend(Canvas canvas) {
    final presence = frame.presence(2);
    if (presence <= 0.01) return;
    RiderCartoon.face(
      canvas,
      center: _friendCenter,
      pop: presence.clamp(0.0, 1.0),
      color: frame.friendColor,
      mood: 0.2 + 0.7 * _ease(_iv(frame.progress(2), 0.72, 0.95)),
      anger: 0,
      lookToward: -_dir,
      squash: 0,
      talking: 0,
      tear: 0,
      ink: frame.ink,
      ambient: (frame.ambient + 0.31) % 1,
    );
  }

  /// Your voice carrying to your friend in soft amber arcs, and the hiss
  /// around you being swept away as it goes.
  void _voice(Canvas canvas) {
    final presence = frame.presence(2);
    if (presence <= 0.01) return;
    final you = _youCenter;
    // Noise specks that hang around you until the app cleans them up.
    final sweep = _iv(frame.progress(2), 0.7, 0.95);
    final rng = math.Random(11);
    for (var i = 0; i < 9; i++) {
      final a = rng.nextDouble() * math.pi * 2;
      final d = _faceR + 10 + rng.nextDouble() * 18;
      final jitter = math.sin(frame.ambient * math.pi * 14 + i) * 1.6;
      // Swept off backwards, the way the wind would take them.
      final at =
          you +
          Offset(math.cos(a) * d + jitter, math.sin(a) * d * 0.8) +
          Offset(-_dir * 40 * _ease(sweep), -6 * sweep);
      final alpha =
          0.55 * presence * (1 - sweep) * _iv(frame.progress(2), 0, 0.2);
      if (alpha <= 0.02) continue;
      canvas.drawCircle(
        at,
        1.6 + rng.nextDouble() * 1.4,
        Paint()..color = const Color(0xFF8E9AA6).withValues(alpha: alpha),
      );
    }

    final strength = _speak * presence;
    if (strength <= 0.01) return;
    final from = you + Offset(_dir * (_faceR + 6), 6);
    final to = _friendCenter + Offset(-_dir * (_faceR + 6), 4);
    for (var i = 0; i < 3; i++) {
      final p = (frame.ambient * 2 + i / 3) % 1;
      final at = Offset.lerp(from, to, p)!;
      final alpha = (math.sin(p * math.pi) * strength).clamp(0.0, 1.0);
      if (alpha <= 0.02) continue;
      final h = 12 + 10 * math.sin(p * math.pi);
      canvas.drawArc(
        Rect.fromCenter(
          center: at + Offset(-_dir * h * 0.4, 0),
          width: h,
          height: h * 1.6,
        ),
        _dir > 0 ? -0.9 : math.pi - 0.9,
        1.8,
        false,
        Paint()
          ..color = frame.youColor.withValues(alpha: alpha * 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// The push-to-talk button you will never need: it appears over you, a
  /// finger reaches for it, a red line strikes it out and it pops.
  void _pushToTalk(Canvas canvas) {
    final presence = frame.presence(2);
    final shown = _back(_button);
    if (presence <= 0.01 || shown <= 0) return;
    final poof = _poof;
    final at = _youCenter + const Offset(0, -_faceR - 34);
    final alpha = presence * (1 - poof);
    if (alpha > 0.01) {
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.scale(shown * (1 + 0.35 * poof));
      // Pressed in while the finger is on it.
      final press = math.sin(math.pi * _press);
      const r = 16.0;
      canvas.drawCircle(
        Offset(0, 2),
        r,
        Paint()..color = Colors.black.withValues(alpha: 0.25 * alpha),
      );
      canvas.drawCircle(
        Offset(0, press * 1.6),
        r - press,
        Paint()..color = frame.paper.withValues(alpha: alpha),
      );
      canvas.drawCircle(
        Offset(0, press * 1.6),
        r - press,
        Paint()
          ..color = frame.ink.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      _mic(canvas, Offset(0, press * 1.6), frame.ink.withValues(alpha: alpha));
      // A fingertip comes down from above, presses, and leaves.
      if (_press > 0 && _press < 1) {
        final reach = math.sin(math.pi * _press);
        final tip = Offset(_dir * 10, -r - 14 + reach * 10);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: tip + const Offset(0, -10),
              width: 11,
              height: 26,
            ),
            const Radius.circular(5.5),
          ),
          Paint()
            ..color = const Color(0xFFE8B48A).withValues(alpha: alpha * reach),
        );
      }
      // The strike, drawn corner to corner.
      final s = _strike;
      if (s > 0) {
        final a = Offset(-r - 2, -r - 2);
        final b = Offset(r + 2, r + 2);
        canvas.drawLine(
          a,
          Offset.lerp(a, b, _ease(s))!,
          Paint()
            ..color = frame.danger.withValues(alpha: alpha)
            ..strokeWidth = 3.6
            ..strokeCap = StrokeCap.round,
        );
      }
      canvas.restore();
    }
    // The pop: a ring of dots flying out.
    if (poof > 0 && poof < 1) {
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4 + 0.3;
        final d = 18 + 22 * _ease(poof);
        canvas.drawCircle(
          at + Offset(math.cos(a) * d, math.sin(a) * d),
          2.6 * (1 - poof),
          Paint()..color = frame.paper.withValues(alpha: presence * (1 - poof)),
        );
      }
    }
  }

  void _mic(Canvas canvas, Offset c, Color color) {
    final paint = Paint()..color = color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: c + const Offset(0, -2.5),
          width: 7,
          height: 12,
        ),
        const Radius.circular(3.5),
      ),
      paint,
    );
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(center: c + const Offset(0, -1), width: 13, height: 13),
      0.2,
      math.pi - 0.4,
      false,
      stroke,
    );
    canvas.drawLine(c + const Offset(0, 5.5), c + const Offset(0, 8.5), stroke);
  }

  // ── Tip 4: the home-screen widget ────────────────────────────────────────

  static const _phoneAtLtr = Offset(254, 104);

  /// A phone rising into view with Tarkk's widget on its home screen. A tap
  /// on the widget, and you hop: straight back on the channel.
  void _phone(Canvas canvas) {
    final presence = frame.presence(3);
    if (presence <= 0.01) return;
    final rise = _drop(_phoneRise);
    final at =
        _p(_phoneAtLtr) +
        Offset(
          0,
          96 * (1 - rise) +
              24 * (1 - presence) +
              math.sin(frame.ambient * math.pi * 4 + 0.6) * 1.6,
        );
    const w = 86.0;
    const h = 146.0;
    final alpha = presence * (0.4 + 0.6 * _iv(rise, 0, 0.5));
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(-_dir * (0.07 + 0.05 * (1 - _ease(_phoneRise))));

    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      const Radius.circular(16),
    );
    canvas.drawRRect(
      body.shift(const Offset(0, 4)),
      Paint()..color = Colors.black.withValues(alpha: 0.25 * alpha),
    );
    canvas.drawRRect(body, Paint()..color = frame.ink.withValues(alpha: alpha));
    final screen = body.deflate(5);
    canvas.drawRRect(
      screen,
      Paint()
        ..shader = ui.Gradient.linear(
          screen.outerRect.topCenter,
          screen.outerRect.bottomCenter,
          [
            const Color(0xFF34506B).withValues(alpha: alpha),
            const Color(0xFF1E2A36).withValues(alpha: alpha),
          ],
        ),
    );
    // The notch.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(0, -h / 2 + 10), width: 22, height: 5),
        const Radius.circular(2.5),
      ),
      Paint()..color = frame.ink.withValues(alpha: alpha),
    );
    // Other apps: a quiet grid under the widget.
    final grid = Paint()..color = Colors.white.withValues(alpha: 0.16 * alpha);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(-22 + col * 22.0, 14 + row * 20.0),
              width: 13,
              height: 13,
            ),
            const Radius.circular(4),
          ),
          grid,
        );
      }
    }

    // The widget, growing out of its corner with a little overshoot, and
    // pressed in where the finger lands.
    final grow = _back(_card);
    if (grow > 0) {
      final press = math.sin(math.pi * _iv(_tap, 0, 0.5)) * 0.06;
      final card = Rect.fromLTWH(-w / 2 + 11, -h / 2 + 22, w - 22, 34);
      canvas.save();
      final pivot = frame.rtl ? card.topRight : card.topLeft;
      canvas.translate(pivot.dx, pivot.dy);
      canvas.scale(grow * (1 - press));
      canvas.translate(-pivot.dx, -pivot.dy);
      final cardShape = RRect.fromRectAndRadius(card, const Radius.circular(9));
      canvas.drawRRect(
        cardShape,
        Paint()..color = frame.paper.withValues(alpha: alpha),
      );
      canvas.drawRRect(
        cardShape,
        Paint()
          ..color = frame.youColor.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      // Who's on air: three little faces lighting up in turn, the first
      // ringed and pulsing as the one talking.
      const colors = [Color(0xFFF5853F), Color(0xFF4FB3BF), Color(0xFFB07CE8)];
      for (var i = 0; i < 3; i++) {
        final lit = _back(_iv(_faces, i * 0.25, i * 0.25 + 0.5));
        if (lit <= 0) continue;
        final c = Offset(
          card.center.dx +
              (frame.rtl ? 1 : -1) * (card.width / 2 - 11 - i * 13.5),
          card.center.dy,
        );
        if (i == 0) {
          final p = frame.ambient * 2 % 1;
          canvas.drawCircle(
            c,
            7 + 5 * p,
            Paint()
              ..color = colors[0].withValues(alpha: 0.6 * (1 - p) * alpha)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4,
          );
        }
        canvas.drawCircle(
          c,
          6.5 * lit,
          Paint()..color = colors[i].withValues(alpha: alpha),
        );
        canvas.drawCircle(
          c,
          6.5 * lit,
          Paint()
            ..color = frame.ink.withValues(alpha: alpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
      // The on-air light, at the far end.
      final live = Offset(
        frame.rtl ? card.left + 11 : card.right - 11,
        card.center.dy,
      );
      final blink = 0.55 + 0.45 * math.sin(frame.ambient * math.pi * 6);
      canvas.drawCircle(
        live,
        3.6,
        Paint()..color = frame.danger.withValues(alpha: alpha * _faces * blink),
      );
      canvas.restore();

      // The tap: a ripple where the finger meets the widget.
      final t = _tap;
      if (t > 0 && t < 1) {
        final c = card.center;
        canvas.drawCircle(
          c,
          5 + 22 * _ease(t),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.7 * (1 - t) * presence)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4,
        );
        canvas.drawCircle(
          c,
          6 * math.sin(math.pi * t),
          Paint()..color = Colors.white.withValues(alpha: 0.6 * presence),
        );
      }
    }
    canvas.restore();

    // From the widget straight to you: a dotted hop across the stage.
    final trail = _trail;
    if (trail > 0) {
      final start = at + Offset(0, -h / 2 + 39);
      final end = _p(youAtLtr) + Offset(_dir * 12, -_faceR - 6);
      final control = Offset((start.dx + end.dx) / 2, -6);
      for (var i = 0; i < 9; i++) {
        final p = i / 8;
        if (p > _ease(trail)) break;
        final fade = (1 - trail) * 0.6 + 0.4 * (1 - p) * (1 - trail);
        canvas.drawCircle(
          _quad(start, control, end, p),
          2.4,
          Paint()
            ..color = frame.youColor.withValues(
              alpha: (presence * (0.25 + fade)).clamp(0.0, 1.0),
            ),
        );
      }
    }
  }

  Offset _quad(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  // ── Celebration ──────────────────────────────────────────────────────────

  /// Sparkles when the widget lands you back on the channel, and on a tap.
  void _sparkles(Canvas canvas) {
    final home = _homeHop * frame.presence(3);
    final tap = frame.hop;
    final c = math.max(home > 0 && home < 1 ? home : 0.0, tap);
    if (c <= 0 || c >= 1) return;
    final center = _youCenter + const Offset(0, -6);
    const colors = [
      Color(0xFFFFC53D),
      Color(0xFF7FD3FF),
      Color(0xFFFF6B8A),
      Color(0xFF7EE787),
    ];
    for (var i = 0; i < 8; i++) {
      final a = -math.pi / 2 + (i - 3.5) * 0.42;
      final dist = _faceR + 8 + 30 * _ease(c);
      final at = center + Offset(math.cos(a) * dist, math.sin(a) * dist);
      RiderCartoon.sparkle(
        canvas,
        at,
        (3.2 + (i % 3)) * (1 - 0.4 * c),
        colors[i % 4].withValues(alpha: (1 - c).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(UsageTipsScenePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
