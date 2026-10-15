import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import 'permission_kind.dart';

/// The scene at the top of the permission primer: one small, physical story
/// per permission, told in the same visual language.
///
///  * **microphone** — sound arrives from both sides and is drawn into a mic.
///  * **camera** — an aperture irises open onto a QR code a scanline reads.
///  * **nearbyDevices** — two phones find each other with Bluetooth pulses.
///  * **nearbyWifi** — one phone fans a hotspot out to the other.
///  * **location** — a pin drops onto the ground and ripples outward to the
///    phones around it (it is about finding *them*, not placing you).
///  * **notifications** — a bell swings, then rests.
///
/// Two morphs are shared by every scene so the whole system behaves alike:
/// [denied] lets the scene settle — motion runs down, colour drains towards
/// grey, a soft pause mark appears; nothing flashes red, because a refusal is
/// a choice, not an error. [granted] blooms a green ring and a drawn tick.
///
/// Cost: one [CustomPainter] in a [RepaintBoundary], driven by four
/// controllers that the painter reads directly (no rebuilds). Strokes and
/// fills only — no blur, no clip, no shader. Under reduced motion the ambient
/// loop holds on a composed frame and the morphs keep their colour change.
class PermissionIllustration extends StatefulWidget {
  const PermissionIllustration({
    required this.kind,
    this.denied = false,
    this.granted = false,
    this.height = 168,
    this.palette,
    super.key,
  });

  final PermissionKind kind;
  final bool denied;
  final bool granted;
  final double height;

  /// Draws against this palette instead of the active theme — for a scene
  /// that sits on the camera's always-black surface.
  final AppPalette? palette;

  @override
  State<PermissionIllustration> createState() => _PermissionIllustrationState();
}

class _PermissionIllustrationState extends State<PermissionIllustration>
    with TickerProviderStateMixin {
  /// The scene's own loop. Each kind reads it at its own pace.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );

  /// One-shot arrival: the subject assembles (the pin drops, the iris opens).
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  late final AnimationController _denied = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  late final AnimationController _granted = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );

  bool _introStarted = false;
  Timer? _settle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAmbient();
    if (!_introStarted) {
      _introStarted = true;
      if (AppMotion.reduced(context)) {
        _intro.value = 1;
        _denied.value = widget.denied ? 1 : 0;
        _granted.value = widget.granted ? 1 : 0;
      } else {
        _intro.forward();
        // A scene that opens already settled still settles *visibly*: it
        // arrives alive and then comes to rest, which is what tells the eye
        // this is a state and not a broken picture.
        if (widget.denied) {
          _settle = Timer(const Duration(milliseconds: 520), () {
            if (mounted && widget.denied) _denied.forward();
          });
        }
        if (widget.granted) _granted.forward();
      }
    }
  }

  @override
  void didUpdateWidget(PermissionIllustration old) {
    super.didUpdateWidget(old);
    if (widget.denied != old.denied) {
      widget.denied ? _denied.forward() : _denied.reverse();
    }
    if (widget.granted != old.granted) {
      widget.granted ? _granted.forward() : _granted.reverse();
    }
    if (widget.kind != old.kind && !AppMotion.reduced(context)) {
      _intro.forward(from: 0);
    }
    _syncAmbient();
  }

  /// Whether [_ambient] is on its endless loop (as opposed to resting, or
  /// easing towards rest).
  bool _looping = false;

  /// The loop only runs while there is something alive to show: a settled
  /// (denied) or finished (granted) scene eases to a composed still and stops
  /// ticking, and reduced motion never starts it.
  void _syncAmbient() {
    final rest = _restFor(widget.kind);
    final reduced = AppMotion.reduced(context);
    if (reduced) {
      _looping = false;
      if (_ambient.isAnimating) _ambient.stop();
      _ambient.value = rest;
      return;
    }
    if (widget.denied || widget.granted) {
      if (_looping) {
        _looping = false;
        _ambient.animateTo(
          rest,
          duration: const Duration(milliseconds: 600),
          curve: AppMotion.easeOut,
        );
      }
      return;
    }
    if (!_looping) {
      _looping = true;
      _ambient.repeat();
    }
  }

  /// A composed still for each scene, used under reduced motion.
  static double _restFor(PermissionKind kind) => switch (kind) {
    PermissionKind.microphone => 0.42,
    PermissionKind.camera => 0.5,
    PermissionKind.nearbyDevices => 0.35,
    PermissionKind.nearbyWifi => 0.55,
    PermissionKind.location => 0.4,
    PermissionKind.notifications => 0.9,
  };

  @override
  void dispose() {
    _settle?.cancel();
    _ambient.dispose();
    _intro.dispose();
    _denied.dispose();
    _granted.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette ?? AppColors.palette;
    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          painter: PermissionScenePainter(
            kind: widget.kind,
            ambient: _ambient,
            intro: _intro,
            denied: _denied,
            granted: _granted,
            accent: widget.kind.accentOn(palette),
            ink: palette.textPrimary,
            muted: palette.textSecondary,
            card: palette.card,
            success: palette.green,
            rtl: Directionality.of(context) == TextDirection.rtl,
          ),
        ),
      ),
    );
  }
}

/// Paints one [PermissionKind]'s scene. Public for golden-style tests only.
class PermissionScenePainter extends CustomPainter {
  PermissionScenePainter({
    required this.kind,
    required this.ambient,
    required this.intro,
    required this.denied,
    required this.granted,
    required this.accent,
    required this.ink,
    required this.muted,
    required this.card,
    required this.success,
    required this.rtl,
  }) : super(repaint: Listenable.merge([ambient, intro, denied, granted]));

  final PermissionKind kind;
  final Animation<double> ambient;
  final Animation<double> intro;
  final Animation<double> denied;
  final Animation<double> granted;
  final Color accent;
  final Color ink;
  final Color muted;
  final Color card;
  final Color success;

  /// Mirrors the directional scenes (the hotspot fans from the reading
  /// start), so the story reads the way the text does.
  final bool rtl;

  // Per-frame values, set at the top of [paint].
  late double _t;
  late double _in;
  late double _d;
  late double _g;
  late double _u;
  late Color _accent;
  late Color _ink;

  @override
  void paint(Canvas canvas, Size size) {
    _t = ambient.value;
    _in = AppMotion.easeOut.transform(intro.value.clamp(0.0, 1.0));
    _d = Curves.easeInOut.transform(denied.value.clamp(0.0, 1.0));
    _g = granted.value.clamp(0.0, 1.0);
    _u = math.min(size.width / 300, size.height / 168);
    final calm = Color.lerp(accent, muted, _d * 0.75)!;
    _accent = Color.lerp(calm, success, Curves.easeOut.transform(_g))!;
    _ink = Color.lerp(ink, muted, _d * 0.5)!;

    final c = size.center(Offset.zero);
    _halo(canvas, c);

    canvas.save();
    // The subject settles in from a hair below full size, like everything
    // else in the app that arrives.
    final s = 0.92 + 0.08 * _in;
    canvas.translate(c.dx, c.dy);
    canvas.scale(s);
    canvas.translate(-c.dx, -c.dy);
    switch (kind) {
      case PermissionKind.microphone:
        _microphone(canvas, c);
      case PermissionKind.camera:
        _camera(canvas, c);
      case PermissionKind.nearbyDevices:
        _phones(canvas, c, wifi: false);
      case PermissionKind.nearbyWifi:
        _phones(canvas, c, wifi: true);
      case PermissionKind.location:
        _location(canvas, c);
      case PermissionKind.notifications:
        _bell(canvas, c);
    }
    canvas.restore();

    if (_d > 0.01) _pauseMark(canvas, c);
    if (_g > 0.01) _tick(canvas, c);
  }

  double get u => _u;

  Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..color = color;

  Paint _fill(Color color) => Paint()..color = color;

  /// Soft concentric discs behind the subject — depth without a blur.
  void _halo(Canvas canvas, Offset c) {
    final a = 0.85 + 0.15 * _in;
    canvas
      ..drawCircle(c, 78 * u * a, _fill(_accent.withValues(alpha: 0.05)))
      ..drawCircle(c, 58 * u * a, _fill(_accent.withValues(alpha: 0.06)))
      ..drawCircle(c, 40 * u * a, _fill(_accent.withValues(alpha: 0.07)));
  }

  /// 0 → 1 → 0 over [p].
  static double _bump(double p) => math.sin(math.pi * p.clamp(0.0, 1.0));

  double get _alive => (1 - _d) * (1 - _g);

  // ── microphone ────────────────────────────────────────────────────────────

  void _microphone(Canvas canvas, Offset c) {
    final mic = c.translate(0, -8 * u);
    // Sound arriving from both sides, drawn in towards the capsule.
    for (var i = 0; i < 3; i++) {
      final p = (_t + i / 3) % 1;
      final r = (118 - 76 * Curves.easeIn.transform(p)) * u;
      final alpha = _bump(p) * 0.85 * _alive * _in;
      if (alpha < 0.01) continue;
      final paint = _stroke(_accent.withValues(alpha: alpha), 3.2 * u);
      const sweep = 0.62;
      canvas
        ..drawArc(
          Rect.fromCircle(center: mic, radius: r),
          math.pi - sweep / 2,
          sweep,
          false,
          paint,
        )
        ..drawArc(
          Rect.fromCircle(center: mic, radius: r),
          -sweep / 2,
          sweep,
          false,
          paint,
        );
    }

    // The capsule fills as the sound lands in it.
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: mic, width: 36 * u, height: 58 * u),
      Radius.circular(18 * u),
    );
    final level = (0.35 + 0.4 * _bump((_t * 2) % 1)) * _alive;
    canvas.drawRRect(body, _fill(_accent.withValues(alpha: 0.12)));
    if (level > 0.01) {
      final top = body.bottom - body.height * level;
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          body.left,
          top,
          body.right,
          body.bottom,
          bottomLeft: Radius.circular(18 * u),
          bottomRight: Radius.circular(18 * u),
          topLeft: Radius.circular(math.min(18 * u, body.bottom - top) / 2),
          topRight: Radius.circular(math.min(18 * u, body.bottom - top) / 2),
        ),
        _fill(_accent.withValues(alpha: 0.28)),
      );
    }
    canvas.drawRRect(body, _stroke(_accent, 3 * u));
    // Grille.
    final grille = _stroke(_accent.withValues(alpha: 0.55), 2 * u);
    for (var i = 0; i < 3; i++) {
      final y = mic.dy - 14 * u + i * 9 * u;
      canvas.drawLine(
        Offset(mic.dx - 8 * u, y),
        Offset(mic.dx + 8 * u, y),
        grille,
      );
    }
    // Cradle, stem, foot.
    final holder = _stroke(_ink.withValues(alpha: 0.8), 3 * u);
    canvas
      ..drawArc(
        Rect.fromCircle(center: mic.translate(0, 6 * u), radius: 27 * u),
        0.15,
        math.pi - 0.3,
        false,
        holder,
      )
      ..drawLine(mic.translate(0, 33 * u), mic.translate(0, 46 * u), holder)
      ..drawLine(
        mic.translate(-14 * u, 46 * u),
        mic.translate(14 * u, 46 * u),
        holder,
      );
  }

  // ── camera ────────────────────────────────────────────────────────────────

  void _camera(Canvas canvas, Offset c) {
    final half = 58 * u;
    final arm = 16 * u;
    // Scanner brackets — the same corners as the app's own QR surface.
    final bracket = _stroke(_accent, 3.4 * u);
    for (final sx in const [-1.0, 1.0]) {
      for (final sy in const [-1.0, 1.0]) {
        final corner = c.translate(sx * half, sy * half);
        canvas
          ..drawLine(corner, corner.translate(-sx * arm, 0), bracket)
          ..drawLine(corner, corner.translate(0, -sy * arm), bracket);
      }
    }

    final outer = 44 * u;
    // Opens on arrival, breathes a little while waiting, closes on a no.
    final breathe = 0.05 * math.sin(_t * 2 * math.pi);
    final open = (_in * (0.86 + breathe) * (1 - _d * 0.9)).clamp(0.04, 1.0);
    final hole = outer * (0.16 + 0.62 * open);

    canvas.drawCircle(c, outer, _fill(_ink.withValues(alpha: 0.07)));

    // The code behind the iris: modules only where the opening shows them,
    // so nothing has to be clipped.
    final module = 6.2 * u;
    const grid = [
      '1110101',
      '1010010',
      '1110110',
      '0001001',
      '1011101',
      '0100110',
      '1101011',
    ];
    final ink = _fill(_ink.withValues(alpha: 0.82));
    for (var y = 0; y < 7; y++) {
      for (var x = 0; x < 7; x++) {
        if (grid[y][x] != '1') continue;
        final center = c.translate((x - 3) * module, (y - 3) * module);
        if ((center - c).distance > hole - module * 0.5) continue;
        canvas.drawRect(
          Rect.fromCenter(
            center: center,
            width: module * 0.82,
            height: module * 0.82,
          ),
          ink,
        );
      }
    }

    // Scanline across the opening.
    final scanAlpha = _alive * _in;
    if (scanAlpha > 0.01 && hole > 8 * u) {
      final y = math.sin(_t * 2 * math.pi) * hole * 0.7;
      final chord = math.sqrt(math.max(0, hole * hole - y * y));
      canvas.drawLine(
        c.translate(-chord + 3 * u, y),
        c.translate(chord - 3 * u, y),
        _stroke(_accent.withValues(alpha: 0.9 * scanAlpha), 2.4 * u),
      );
    }

    // Iris blades: from each corner of the opening, a straight edge out to
    // the barrel, twisted as it opens.
    final rot = -0.9 * open;
    final blade = _stroke(_accent.withValues(alpha: 0.9), 2.2 * u);
    final fillBlade = _fill(Color.lerp(card, _accent, 0.16)!);
    final vertices = [
      for (var k = 0; k < 6; k++)
        c + Offset.fromDirection(rot + k * math.pi / 3, hole),
    ];
    for (var k = 0; k < 6; k++) {
      final v = vertices[k];
      final next = vertices[(k + 1) % 6];
      final dir = v - next;
      final unit = dir / dir.distance;
      final end = _rayToCircle(v, unit, c, outer);
      final path = Path()
        ..moveTo(v.dx, v.dy)
        ..lineTo(end.dx, end.dy)
        ..arcToPoint(
          _rayToCircle(
            next,
            (next - vertices[(k + 2) % 6]) /
                (next - vertices[(k + 2) % 6]).distance,
            c,
            outer,
          ),
          radius: Radius.circular(outer),
        )
        ..lineTo(next.dx, next.dy)
        ..close();
      canvas.drawPath(path, fillBlade);
      canvas.drawLine(v, end, blade);
    }
    canvas.drawCircle(c, outer, _stroke(_accent, 3 * u));
  }

  static Offset _rayToCircle(Offset p, Offset d, Offset c, double r) {
    final f = p - c;
    final b = f.dx * d.dx + f.dy * d.dy;
    final cc = f.dx * f.dx + f.dy * f.dy - r * r;
    final disc = math.max(0.0, b * b - cc);
    final s = -b + math.sqrt(disc);
    return p + d * s;
  }

  // ── phones (Bluetooth / hotspot) ──────────────────────────────────────────

  void _phones(Canvas canvas, Offset c, {required bool wifi}) {
    final gap = 82 * u;
    final dir = rtl ? -1.0 : 1.0;
    final source = c.translate(-gap * dir, 0);
    final sink = c.translate(gap * dir, 0);

    if (wifi) {
      // The hotspot fans out from the first phone towards the second.
      for (var i = 0; i < 3; i++) {
        final p = (_t + i / 3) % 1;
        final r = (22 + 150 * p) * u;
        final alpha = _bump(p) * 0.8 * _alive * _in;
        if (alpha < 0.01) continue;
        canvas.drawArc(
          Rect.fromCircle(center: source, radius: r),
          (rtl ? math.pi : 0) - 0.42,
          0.84,
          false,
          _stroke(_accent.withValues(alpha: alpha), 3 * u),
        );
      }
    } else {
      // Both phones pulse; the pulses take turns, like a conversation.
      for (final (phone, offset) in [(source, 0.0), (sink, 0.5)]) {
        for (var i = 0; i < 2; i++) {
          final p = (_t + offset + i / 2) % 1;
          final r = (26 + 48 * p) * u;
          final alpha = (1 - p) * 0.55 * _alive * _in;
          if (alpha < 0.01) continue;
          canvas.drawCircle(
            phone,
            r,
            _stroke(_accent.withValues(alpha: alpha), 2.2 * u),
          );
        }
      }
    }

    // The link between them: dashes, with a light travelling along it. On a
    // refusal the middle opens up — the two phones stay, the link rests.
    final split = _d * 26 * u;
    final dash = _stroke(_accent.withValues(alpha: 0.5), 2.4 * u);
    final from = source.translate(24 * u * dir, 0);
    final to = sink.translate(-24 * u * dir, 0);
    final length = (to.dx - from.dx).abs();
    for (var x = 0.0; x < length; x += 10 * u) {
      final a = from.dx + x * dir;
      final b = from.dx + math.min(x + 5 * u, length) * dir;
      if ((a - c.dx).abs() < split || (b - c.dx).abs() < split) continue;
      canvas.drawLine(Offset(a, c.dy), Offset(b, c.dy), dash);
    }
    final travel = (_t * (wifi ? 1 : 2)) % 1;
    final dotAlpha = _alive * _in * _bump(travel);
    if (dotAlpha > 0.01) {
      final dot = Offset(from.dx + length * travel * dir, c.dy);
      canvas
        ..drawCircle(
          dot,
          7 * u,
          _fill(_accent.withValues(alpha: 0.18 * dotAlpha)),
        )
        ..drawCircle(dot, 3.4 * u, _fill(_accent.withValues(alpha: dotAlpha)));
    }

    // Arriving signal lights the second phone's screen.
    final glow = wifi
        ? _bump(((_t + 0.0) % 1)) * 0.5 * _alive
        : _bump((_t * 2 + 0.5) % 1) * 0.4 * _alive;
    _phone(canvas, source, 0.25 * _alive + 0.1);
    _phone(canvas, sink, 0.1 + glow);

    // Centre badge naming the radio.
    canvas
      ..drawCircle(c, 15 * u, _fill(card))
      ..drawCircle(c, 15 * u, _stroke(_accent, 2.2 * u));
    if (wifi) {
      final w = _stroke(_accent, 2 * u);
      final dot = c.translate(0, 5 * u);
      for (final r in [5.5, 10.0]) {
        canvas.drawArc(
          Rect.fromCircle(center: dot, radius: r * u),
          -math.pi / 2 - 0.75,
          1.5,
          false,
          w,
        );
      }
      canvas.drawCircle(dot, 1.8 * u, _fill(_accent));
    } else {
      // The Bluetooth rune.
      final rune = Path()
        ..moveTo(c.dx - 5 * u, c.dy - 4.5 * u)
        ..lineTo(c.dx + 5 * u, c.dy + 4.5 * u)
        ..lineTo(c.dx, c.dy + 9 * u)
        ..lineTo(c.dx, c.dy - 9 * u)
        ..lineTo(c.dx + 5 * u, c.dy - 4.5 * u)
        ..lineTo(c.dx - 5 * u, c.dy + 4.5 * u);
      canvas.drawPath(rune, _stroke(_accent, 2 * u));
    }
  }

  void _phone(Canvas canvas, Offset center, double screenGlow) {
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 40 * u, height: 70 * u),
      Radius.circular(9 * u),
    );
    final screen = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center.translate(0, 1 * u),
        width: 32 * u,
        height: 54 * u,
      ),
      Radius.circular(4 * u),
    );
    canvas
      ..drawRRect(body, _fill(card))
      ..drawRRect(
        screen,
        _fill(_accent.withValues(alpha: screenGlow.clamp(0.0, 1.0) * 0.6)),
      )
      ..drawRRect(body, _stroke(_ink.withValues(alpha: 0.75), 2.4 * u))
      ..drawLine(
        center.translate(-4 * u, -31 * u),
        center.translate(4 * u, -31 * u),
        _stroke(_ink.withValues(alpha: 0.5), 1.6 * u),
      );
  }

  // ── location ──────────────────────────────────────────────────────────────

  void _location(Canvas canvas, Offset c) {
    final ground = c.translate(0, 44 * u);

    // Ripples across the ground, reaching the phones around the rider.
    for (var i = 0; i < 3; i++) {
      final p = (_t + i / 3) % 1;
      final rx = (16 + 104 * p) * u;
      final alpha = (1 - p) * 0.6 * _alive * _in;
      if (alpha < 0.01) continue;
      canvas.drawOval(
        Rect.fromCenter(center: ground, width: rx * 2, height: rx * 0.56),
        _stroke(_accent.withValues(alpha: alpha), 2 * u),
      );
    }
    // Phones the ripple finds: they light up as it passes them.
    for (final (dx, dy, at) in [(-92.0, 8.0, 0.75), (86.0, -4.0, 0.68)]) {
      final spot = ground.translate(dx * u, dy * u);
      final hit = _bump(((_t * 3) % 1 - at + 1) % 1 * 3) * _alive;
      final r = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: spot.translate(0, -9 * u),
          width: 13 * u,
          height: 22 * u,
        ),
        Radius.circular(3 * u),
      );
      canvas
        ..drawRRect(r, _fill(Color.lerp(card, _accent, 0.15 + 0.5 * hit)!))
        ..drawRRect(r, _stroke(_ink.withValues(alpha: 0.6), 1.6 * u));
    }

    // The pin drops in on arrival with a damped bounce, then stays put.
    final drop = intro.value.clamp(0.0, 1.0);
    final fall = drop < 0.38
        ? -1 + Curves.easeIn.transform(drop / 0.38)
        : -math.exp(-7 * (drop - 0.38)) * math.sin(13 * (drop - 0.38)) * 0.18;
    final lift = _d * 10 * u;
    final tip = ground.translate(0, fall * 90 * u - lift);
    // Contact shadow tightens as the pin lands.
    final shadowW = (14 + 10 * (1 + fall.clamp(-1.0, 0.0))) * u;
    canvas.drawOval(
      Rect.fromCenter(
        center: ground,
        width: shadowW * 2,
        height: shadowW * 0.5,
      ),
      _fill(_ink.withValues(alpha: 0.12 * (1 - _d * 0.6))),
    );

    final head = tip.translate(0, -50 * u);
    const r = 23.0;
    final pin = Path()
      ..moveTo(tip.dx, tip.dy)
      ..cubicTo(
        tip.dx - 8 * u,
        tip.dy - 14 * u,
        head.dx - r * u,
        head.dy + 16 * u,
        head.dx - r * u,
        head.dy,
      )
      ..arcToPoint(
        Offset(head.dx + r * u, head.dy),
        radius: const Radius.circular(r) * u,
      )
      ..cubicTo(
        head.dx + r * u,
        head.dy + 16 * u,
        tip.dx + 8 * u,
        tip.dy - 14 * u,
        tip.dx,
        tip.dy,
      )
      ..close();
    canvas
      ..drawPath(pin, _fill(Color.lerp(card, _accent, 0.9 - 0.55 * _d)!))
      ..drawPath(pin, _stroke(_accent, 2.4 * u))
      ..drawCircle(head, 8.5 * u, _fill(card));
  }

  // ── notifications ─────────────────────────────────────────────────────────

  void _bell(Canvas canvas, Offset c) {
    final pivot = c.translate(0, -42 * u);
    // Swings for the first part of each loop, decaying, then rests.
    final p = _t;
    final swing = p < 0.6
        ? math.sin(p / 0.6 * 4 * math.pi) * math.exp(-3.2 * p / 0.6) * 0.32
        : 0.0;
    final angle = swing * _alive * _in;
    final speed = p < 0.6 ? math.exp(-3.2 * p / 0.6) : 0.0;

    // Ringing marks on both sides while it moves.
    final ring = speed * _alive * _in;
    if (ring > 0.02) {
      final marks = _stroke(_accent.withValues(alpha: 0.75 * ring), 2.6 * u);
      for (final side in const [-1.0, 1.0]) {
        for (var i = 0; i < 2; i++) {
          final rr = (50 + i * 12) * u;
          canvas.drawArc(
            Rect.fromCircle(center: c.translate(0, -2 * u), radius: rr),
            (side < 0 ? math.pi : 0) - 0.32,
            0.64,
            false,
            marks,
          );
        }
      }
    }

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(angle);
    canvas.translate(-pivot.dx, -pivot.dy);
    final top = pivot.translate(0, 8 * u);
    final rim = c.translate(0, 30 * u);
    // Round shoulders, a near-straight waist, and a flare at the lip.
    final bell = Path()
      ..moveTo(top.dx, top.dy)
      ..cubicTo(
        top.dx + 22 * u,
        top.dy,
        top.dx + 26 * u,
        top.dy + 18 * u,
        rim.dx + 25 * u,
        rim.dy - 16 * u,
      )
      ..quadraticBezierTo(
        rim.dx + 27 * u,
        rim.dy - 3 * u,
        rim.dx + 36 * u,
        rim.dy,
      )
      ..lineTo(rim.dx - 36 * u, rim.dy)
      ..quadraticBezierTo(
        rim.dx - 27 * u,
        rim.dy - 3 * u,
        rim.dx - 25 * u,
        rim.dy - 16 * u,
      )
      ..cubicTo(
        top.dx - 26 * u,
        top.dy + 18 * u,
        top.dx - 22 * u,
        top.dy,
        top.dx,
        top.dy,
      )
      ..close();
    // The clapper lags the bell a touch, which is what sells the weight.
    final clapper = rim.translate(-swing * 18 * u * _alive, 8 * u);
    canvas
      ..drawCircle(clapper, 7 * u, _fill(_accent))
      ..drawPath(bell, _fill(Color.lerp(card, _accent, 0.22)!))
      ..drawPath(bell, _stroke(_accent, 3 * u))
      ..drawLine(
        rim.translate(-38 * u, 0),
        rim.translate(38 * u, 0),
        _stroke(_accent, 3.4 * u),
      )
      ..drawCircle(pivot.translate(0, 3 * u), 5 * u, _stroke(_accent, 2.6 * u));
    canvas.restore();

    // The badge pops in once the bell has arrived.
    final badge = Curves.easeOutBack.transform(
      ((intro.value - 0.55) / 0.45).clamp(0.0, 1.0),
    );
    final badgeScale = badge * (1 - _d) * (1 - _g);
    if (badgeScale > 0.01) {
      final at = c.translate(26 * u, -30 * u);
      canvas
        ..drawCircle(at, 9 * u * badgeScale, _fill(card))
        ..drawCircle(at, 7 * u * badgeScale, _fill(_accent));
    }
  }

  // ── shared morphs ─────────────────────────────────────────────────────────

  /// Where the pause mark and the tick sit: on the subject's shoulder, or —
  /// between two phones — right over the link they share.
  Offset _markAnchor(Offset c) => switch (kind) {
    PermissionKind.nearbyDevices ||
    PermissionKind.nearbyWifi => c.translate(0, -38 * u),
    _ => c.translate((rtl ? -1 : 1) * 46 * u, -42 * u),
  };

  /// The refusal mark: a small round pause sign, settling in beside the
  /// subject. Calm on purpose — grey, not red.
  void _pauseMark(Canvas canvas, Offset c) {
    final k = Curves.easeOutBack.transform(_d.clamp(0.0, 1.0));
    final at = _markAnchor(c);
    final r = 14 * u * k;
    canvas
      ..drawCircle(at, r + 3 * u * k, _fill(card))
      ..drawCircle(at, r, _fill(muted.withValues(alpha: 0.22)))
      ..drawCircle(at, r, _stroke(muted, 2 * u));
    final bar = _stroke(ink.withValues(alpha: 0.8), 2.6 * u);
    canvas
      ..drawLine(
        at.translate(-3.5 * u * k, -5 * u * k),
        at.translate(-3.5 * u * k, 5 * u * k),
        bar,
      )
      ..drawLine(
        at.translate(3.5 * u * k, -5 * u * k),
        at.translate(3.5 * u * k, 5 * u * k),
        bar,
      );
  }

  /// The grant: a ring blooms out once and a tick is drawn in.
  void _tick(Canvas canvas, Offset c) {
    final at = _markAnchor(c);
    final bloom = Curves.easeOut.transform(_g);
    canvas.drawCircle(
      at,
      (14 + 30 * bloom) * u,
      _stroke(success.withValues(alpha: 0.5 * (1 - bloom)), 2 * u),
    );
    final pop = Curves.easeOutBack.transform((_g / 0.55).clamp(0.0, 1.0));
    canvas
      ..drawCircle(at, 17 * u * pop, _fill(card))
      ..drawCircle(at, 14 * u * pop, _fill(success));
    final draw = ((_g - 0.35) / 0.5).clamp(0.0, 1.0);
    if (draw > 0) {
      final a = at.translate(-6 * u, 0.5 * u);
      final b = at.translate(-1.5 * u, 5 * u);
      final e = at.translate(6.5 * u, -4.5 * u);
      final path = Path()..moveTo(a.dx, a.dy);
      if (draw < 0.4) {
        final q = Offset.lerp(a, b, draw / 0.4)!;
        path.lineTo(q.dx, q.dy);
      } else {
        path.lineTo(b.dx, b.dy);
        final q = Offset.lerp(b, e, (draw - 0.4) / 0.6)!;
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path, _stroke(card, 2.8 * u));
    }
  }

  @override
  bool shouldRepaint(PermissionScenePainter old) =>
      old.kind != kind ||
      old.accent != accent ||
      old.ink != ink ||
      old.muted != muted ||
      old.card != card ||
      old.rtl != rtl ||
      old.ambient != ambient;
}
