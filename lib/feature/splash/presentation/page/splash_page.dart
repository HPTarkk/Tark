import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/version_badge.dart';

/// Branded splash shown on cold start (unless skipped via Settings), capped
/// hard at ~3.5s regardless of how the entrance animation plays out — the
/// navigation timer is a plain wall-clock delay, deliberately decoupled from
/// any [AnimationController], so the cap can never be exceeded even if a
/// curve/duration changes later.
///
/// Visual concept: "first transmission" — a slow aurora of warm light drifts
/// behind a frosted-glass emblem disc carrying the TARK mark. A luminous halo
/// ring draws itself around the disc with a small comet orbiting it, and thin
/// broadcast ripples radiate outward like a keyed-up transmitter. The wordmark
/// rises out of a mask with a gloss sweep, and a hairline progress bar at the
/// bottom fills across the real wall-clock wait before a quick dip-out exit.
///
/// Feature-pure by design: it knows nothing about routing. Whoever builds it
/// (the app-layer router) supplies [onFinished], which resolves where to go
/// next and navigates — keeping this page a plain, reusable widget.
class SplashPage extends StatefulWidget {
  const SplashPage._({required this.onFinished});

  final Future<void> Function() onFinished;

  static Widget buildPage({required Future<void> Function() onFinished}) =>
      SplashPage._(onFinished: onFinished);

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  static const _kDisplayDuration = Duration(milliseconds: 3500);

  /// How long before navigation the dip-out exit starts. The exit is pure
  /// polish — navigation itself stays on the wall-clock timer below.
  static const _kExitLead = Duration(milliseconds: 320);

  /// One-shot entrance choreography: backdrop fade, light sweep, halo draw,
  /// disc pop, mark reveal, wordmark rise, footer fade. Runs once per launch.
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..forward();

  /// Quick dip-out (fade + slight zoom-through) just before navigation.
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: _kExitLead,
  );

  /// Slow ambient loop — aurora drift, bokeh twinkle, halo shimmer rotation,
  /// comet orbit phase.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  )..repeat();

  /// Idle breathing — glow and rim intensity.
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  /// Broadcast ripple cycle — three staggered rings expanding outward.
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  /// Wordmark gloss sweep cycle (the band only occupies part of the cycle,
  /// so the shimmer reads as an occasional glint rather than a strobe).
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  /// Fills the footer hairline across the full display duration, so the bar
  /// reflects the actual wall-clock wait.
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _kDisplayDuration,
  )..forward();

  late final Animation<double> _backdropFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.0, 0.30, curve: Curves.easeOut),
  );
  late final Animation<double> _haloDraw = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.10, 0.55, curve: Curves.easeInOutCubic),
  );
  late final Animation<double> _discPop = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.28, 0.72, curve: Curves.easeOutBack),
  );
  late final Animation<double> _discFade = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.28, 0.50, curve: Curves.easeOut),
  );
  late final Animation<double> _markIn = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.42, 0.75, curve: Curves.easeOutCubic),
  );
  late final Animation<double> _rippleGate = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.55, 1.0, curve: Curves.easeOut),
  );
  late final Animation<double> _subIn = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.68, 0.95, curve: Curves.easeOut),
  );
  late final Animation<double> _footIn = CurvedAnimation(
    parent: _entrance,
    curve: const Interval(0.78, 1.0, curve: Curves.easeOut),
  );
  late final Animation<double> _breathe = CurvedAnimation(
    parent: _breath,
    curve: Curves.easeInOut,
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(_kDisplayDuration - _kExitLead, () {
      if (mounted) _exit.forward();
    });
    Future.delayed(_kDisplayDuration, () {
      if (mounted) widget.onFinished();
    });
  }

  @override
  void dispose() {
    _entrance.dispose();
    _exit.dispose();
    _ambient.dispose();
    _breath.dispose();
    _ripple.dispose();
    _shimmer.dispose();
    _progress.dispose();
    super.dispose();
  }

  /// Neon-sign ignition flicker for the wordmark: opacity hard-cuts through
  /// an irregular dim/bright strike pattern before locking on — uneven steps
  /// read like a tube catching, not a metronome. Driven by the raw entrance
  /// clock so the cuts stay hard, never eased.
  static const _flickerPattern = [
    0.15, 1.0, 0.25, 0.9, 0.1, 1.0, 0.45, 1.0, 0.2, 1.0, //
  ];

  /// Entrance-clock position where the first strike hits.
  static const _kFlickerStart = 0.55;

  /// Fraction of the remaining window spent striking before lock-on.
  static const _kFlickerSettle = 0.8;

  bool get _wordmarkLocked =>
      (_entrance.value - _kFlickerStart) / (1 - _kFlickerStart) >=
      _kFlickerSettle;

  double _flickerEnvelope(double t) {
    if (t <= _kFlickerStart) return 0.0;
    final local = ((t - _kFlickerStart) / (1 - _kFlickerStart)).clamp(
      0.0,
      1.0,
    );
    if (local >= _kFlickerSettle) return 1.0;
    return _flickerPattern[((local / _kFlickerSettle) *
            _flickerPattern.length)
        .floor()];
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: _exit,
        builder: (context, child) {
          final out = Curves.easeIn.transform(_exit.value);
          return Opacity(
            opacity: 1 - out,
            child: Transform.scale(scale: 1 + 0.04 * out, child: child),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_entrance, _ambient, _breath]),
                builder: (context, _) => CustomPaint(
                  painter: _AuroraPainter(
                    fade: _backdropFade.value,
                    entrance: _entrance.value,
                    drift: _ambient.value,
                    breath: _breathe.value,
                    amber: AppColors.amber,
                    amberDim: AppColors.amberDim,
                    haze: AppColors.border,
                    shade: Color.lerp(
                      AppColors.background,
                      Colors.black,
                      0.6,
                    )!,
                  ),
                  size: Size.infinite,
                ),
              ),
            ),
            Center(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _entrance,
                  _ambient,
                  _breath,
                  _ripple,
                  _shimmer,
                ]),
                builder: (context, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildEmblem(),
                    const SizedBox(height: 10),
                    _buildWordmark(s.app_name),
                    const SizedBox(height: 16),
                    _buildSubtitle(s.app_subtitle),
                  ],
                ),
              ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmblem() {
    return SizedBox(
      width: 360,
      height: 360,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(360, 360),
            painter: _BroadcastRipplePainter(
              t: _ripple.value,
              gate: _rippleGate.value,
              amber: AppColors.amber,
            ),
          ),
          CustomPaint(
            size: const Size(360, 360),
            painter: _HaloRingPainter(
              draw: _haloDraw.value,
              spin: _ambient.value,
              breath: _breathe.value,
              amber: AppColors.amber,
            ),
          ),
          _buildGlassDisc(),
        ],
      ),
    );
  }

  /// Frosted-glass disc: a real [BackdropFilter] blur over the aurora, a soft
  /// radial surface tint, a diagonal specular sheen, and the monogram mark.
  Widget _buildGlassDisc() {
    final b = _breathe.value;
    return Opacity(
      opacity: _discFade.value,
      child: Transform.scale(
        scale: 0.7 + 0.3 * _discPop.value,
        child: Container(
          width: 168,
          height: 168,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.amber.withAlpha((36 + 58 * b).toInt()),
                blurRadius: 46 + 18 * b,
                spreadRadius: 2,
              ),
            ],
          ),
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.35, -0.45),
                    radius: 1.25,
                    colors: [
                      AppColors.card.withAlpha(205),
                      AppColors.card.withAlpha(130),
                    ],
                  ),
                  border: Border.all(
                    color: AppColors.amber.withAlpha((70 + 70 * b).toInt()),
                    width: 1.2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Specular sheen — a faint diagonal light catch that sells
                    // the glass reading in both palettes.
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x1AFFFFFF), Color(0x00FFFFFF)],
                        ),
                      ),
                    ),
                    Center(
                      child: Opacity(
                        opacity: _markIn.value,
                        child: Transform.scale(
                          scale: 0.85 + 0.15 * _markIn.value,
                          child: CustomPaint(
                            size: const Size(86, 74),
                            painter: _MonogramGlyphPainter(
                              pulse: b,
                              color: AppColors.amber,
                              colorDim: AppColors.amberDim,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Wordmark: ignites in place like a neon sign — no positional movement,
  /// just the hard-cut strike pattern of [_flickerEnvelope], with a glow
  /// that flares on each bright strike and then settles into a gentle
  /// breathing halo crossed by a periodic gloss sweep. (No per-letter
  /// animation — the Persian wordmark would lose its cursive joining if
  /// split into characters.)
  Widget _buildWordmark(String name) {
    final flick = _flickerEnvelope(_entrance.value);
    final glowAlpha = _wordmarkLocked
        ? (50 + 40 * _breathe.value).toInt()
        : (130 * flick).toInt();
    final glossT = Curves.easeInOut.transform(
      ((_shimmer.value - 0.15) / 0.5).clamp(0.0, 1.0),
    );
    final dx = -2.0 + 4.0 * glossT;

    Widget text = Text(
      name,
      style: TextStyle(
        color: Colors.white,
        fontSize: 40,
        fontWeight: FontWeight.w900,
        letterSpacing: 9,
        height: 1.2,
        // White here on purpose: the srcIn mask below re-tints the whole
        // raster (glyphs and this halo) with the amber gradient.
        shadows: [
          Shadow(color: Colors.white.withAlpha(glowAlpha), blurRadius: 28),
        ],
      ),
    );
    text = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [AppColors.amber, AppColors.amberDim],
      ).createShader(rect),
      child: text,
    );
    text = ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment(dx - 0.6, -1),
        end: Alignment(dx + 0.6, 1),
        colors: [
          const Color(0x00FFFFFF),
          Colors.white.withAlpha((110 * flick).toInt()),
          const Color(0x00FFFFFF),
        ],
      ).createShader(rect),
      child: text,
    );

    return Opacity(opacity: flick, child: text);
  }

  Widget _buildSubtitle(String subtitle) {
    final t = _subIn.value;
    final flank = Container(
      width: 26 * t,
      height: 1,
      color: AppColors.amber.withAlpha(90),
    );
    return Opacity(
      opacity: t,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            flank,
            const SizedBox(width: 12),
            Text(
              subtitle,
              style: TextStyle(
                color: AppColors.textSecondary.withAlpha(180),
                fontSize: 12,
                letterSpacing: 4,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            flank,
          ],
        ),
      ),
    );
  }

  /// Bottom hairline that fills from the center across the real wall-clock
  /// wait, with the app version beneath it.
  Widget _buildFooter() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 44),
        child: AnimatedBuilder(
          animation: Listenable.merge([_entrance, _progress]),
          builder: (context, _) => Opacity(
            opacity: _footIn.value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 148,
                  height: 2.4,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.amber.withAlpha(28),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Align(
                        child: FractionallySizedBox(
                          widthFactor: Curves.easeInOutSine.transform(
                            _progress.value,
                          ),
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AppColors.amberDim,
                                  AppColors.amber,
                                  AppColors.amberDim,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.amber.withAlpha(90),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                VersionBadge(color: AppColors.textSecondary.withAlpha(150)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Ambient background ────────────────────────────────────────────────────────

/// One soft-blurred background speck — "dust in the beam" depth, generated
/// once with a fixed seed so the layout is stable across rebuilds.
class _Mote {
  final double dx, dy, radius, freq, phase;

  const _Mote(this.dx, this.dy, this.radius, this.freq, this.phase);
}

final List<_Mote> _motes = _generateMotes();

List<_Mote> _generateMotes() {
  final rnd = Random(11);
  final motes = <_Mote>[];
  while (motes.length < 16) {
    final dx = rnd.nextDouble();
    final dy = rnd.nextDouble();
    // Keep clear of the emblem, which sits slightly above screen center.
    final ddx = dx - 0.5, ddy = dy - 0.44;
    if (ddx * ddx + ddy * ddy < 0.045) continue;
    motes.add(
      _Mote(
        dx,
        dy,
        1.6 + rnd.nextDouble() * 3.0,
        0.4 + rnd.nextDouble() * 1.2,
        rnd.nextDouble(),
      ),
    );
  }
  return motes;
}

/// Full-bleed ambient layer: three large drifting gradient blobs (warm amber,
/// deep amber, and a cool counter-tone), soft-blurred motes, an edge vignette
/// that pulls focus to the emblem, and a single diagonal light sweep that
/// crosses the screen once during the entrance.
class _AuroraPainter extends CustomPainter {
  final double fade;
  final double entrance;
  final double drift;
  final double breath;
  final Color amber;
  final Color amberDim;
  final Color haze;
  final Color shade;

  const _AuroraPainter({
    required this.fade,
    required this.entrance,
    required this.drift,
    required this.breath,
    required this.amber,
    required this.amberDim,
    required this.haze,
    required this.shade,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0.01) return;
    final d = 2 * pi * drift;

    _blob(
      canvas,
      size,
      Offset(0.22 + 0.05 * sin(d), 0.20 + 0.04 * cos(d * 0.8)),
      0.55,
      amber,
      ((24 + 10 * breath) * fade).toInt(),
    );
    _blob(
      canvas,
      size,
      Offset(0.82 - 0.06 * cos(d * 0.7), 0.74 + 0.05 * sin(d * 0.9)),
      0.50,
      amberDim,
      (18 * fade).toInt(),
    );
    _blob(
      canvas,
      size,
      Offset(0.72 + 0.05 * sin(d * 0.6 + 1), 0.14 + 0.04 * cos(d * 0.5)),
      0.45,
      haze,
      (120 * fade).toInt(),
    );

    _paintMotes(canvas, size);

    // Edge vignette.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..shader =
            RadialGradient(
              colors: [shade.withAlpha(0), shade.withAlpha(70)],
              stops: const [0.55, 1.0],
            ).createShader(
              Rect.fromCircle(
                center: Offset(size.width / 2, size.height / 2),
                radius: size.longestSide * 0.75,
              ),
            ),
    );

    _paintLightSweep(canvas, size);
  }

  void _blob(
    Canvas canvas,
    Size size,
    Offset unitCenter,
    double unitRadius,
    Color color,
    int alpha,
  ) {
    if (alpha <= 0) return;
    final center = Offset(
      unitCenter.dx * size.width,
      unitCenter.dy * size.height,
    );
    final radius = unitRadius * size.longestSide;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color.withAlpha(alpha), color.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  void _paintMotes(Canvas canvas, Size size) {
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    for (final m in _motes) {
      final t = drift * m.freq + m.phase;
      final pos =
          Offset(m.dx * size.width, m.dy * size.height) +
          Offset(sin(2 * pi * t), cos(2 * pi * t * 0.8)) * 9;
      final twinkle = 0.5 + 0.5 * sin(2 * pi * (t + m.phase));
      canvas.drawCircle(
        pos,
        m.radius,
        paint..color = amber.withAlpha(((26 + 52 * twinkle) * fade).toInt()),
      );
    }
  }

  void _paintLightSweep(Canvas canvas, Size size) {
    final local = ((entrance - 0.05) / 0.5).clamp(0.0, 1.0);
    final envelope = sin(pi * local);
    if (envelope <= 0.01) return;
    canvas.save();
    canvas.translate(size.width * (-0.35 + 1.7 * local), size.height * 0.5);
    canvas.rotate(-0.4);
    final beamRect = Rect.fromLTWH(
      -70,
      -size.height * 1.6,
      140,
      size.height * 3.2,
    );
    canvas.drawRect(
      beamRect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            amber.withAlpha(0),
            amber.withAlpha((70 * envelope).toInt()),
            amber.withAlpha(0),
          ],
        ).createShader(beamRect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.fade != fade ||
      old.entrance != entrance ||
      old.drift != drift ||
      old.breath != breath ||
      old.amber != amber;
}

// ── Emblem layers ─────────────────────────────────────────────────────────────

/// Thin "keyed-up transmitter" rings expanding outward from the halo and
/// fading as they travel — three of them, evenly staggered.
class _BroadcastRipplePainter extends CustomPainter {
  final double t;
  final double gate;
  final Color amber;

  const _BroadcastRipplePainter({
    required this.t,
    required this.gate,
    required this.amber,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (gate <= 0.01) return;
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    for (var i = 0; i < 3; i++) {
      final f = (t + i / 3) % 1.0;
      final radius = 104 + 74 * Curves.easeOut.transform(f);
      final alpha = ((1 - f) * (1 - f) * 80 * gate).toInt();
      if (alpha <= 2) continue;
      canvas.drawCircle(center, radius, paint..color = amber.withAlpha(alpha));
    }
  }

  @override
  bool shouldRepaint(_BroadcastRipplePainter old) =>
      old.t != t || old.gate != gate || old.amber != amber;
}

/// The luminous halo around the glass disc: an arc that draws itself in on
/// entrance, carries a slowly rotating brightness (sweep-gradient shimmer),
/// a faint static outer ring, and a small comet orbiting once the halo has
/// finished drawing.
class _HaloRingPainter extends CustomPainter {
  final double draw;
  final double spin;
  final double breath;
  final Color amber;

  const _HaloRingPainter({
    required this.draw,
    required this.spin,
    required this.breath,
    required this.amber,
  });

  static const _radius = 102.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (draw <= 0.01) return;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: _radius);

    canvas.drawArc(
      rect,
      -pi / 2,
      2 * pi * draw,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            amber.withAlpha(30),
            amber.withAlpha((190 + 50 * breath).toInt()),
            amber.withAlpha(30),
          ],
          transform: GradientRotation(2 * pi * spin),
        ).createShader(rect),
    );

    // Faint static outer ring for depth.
    canvas.drawCircle(
      center,
      130,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = amber.withAlpha(((14 + 10 * breath) * draw).toInt()),
    );

    // Comet — fades in as the halo finishes drawing, then orbits forever.
    // The tail is a single gradient-stroked arc (not stamped dots) so it
    // reads as one smooth streak.
    final cometGate = ((draw - 0.85) / 0.15).clamp(0.0, 1.0);
    if (cometGate <= 0.01) return;
    final head = -pi / 2 + 2 * pi * ((spin * 3) % 1.0);
    const trailSweep = 0.9;
    canvas.drawArc(
      rect,
      head - trailSweep,
      trailSweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: trailSweep,
          colors: [amber.withAlpha(0), amber.withAlpha((210 * cometGate).toInt())],
          transform: GradientRotation(head - trailSweep),
        ).createShader(rect),
    );
    final headPos = center + Offset(cos(head), sin(head)) * _radius;
    canvas.drawCircle(
      headPos,
      3.4,
      Paint()
        ..color = amber.withAlpha((200 * cometGate).toInt())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  @override
  bool shouldRepaint(_HaloRingPainter old) =>
      old.draw != draw ||
      old.spin != spin ||
      old.breath != breath ||
      old.amber != amber;
}

/// The badge's center mark — the TARK brand mark (two swept wing pieces
/// forming a "T", split by a diagonal gap), traced from the vector logo and
/// breathing gently in time with [pulse]. This is the one mark no other
/// walkie-talkie app has. Static (no image assets, no extra ticker) so the
/// very first splash frame has nothing to wait on.
class _MonogramGlyphPainter extends CustomPainter {
  final double pulse;
  final Color color;
  final Color colorDim;

  const _MonogramGlyphPainter({
    required this.pulse,
    required this.color,
    required this.colorDim,
  });

  // Traced 1:1 from the source logo (473x409 viewBox, borderless). Two
  // closed contours — left wing, right wing + stem — left unconnected on
  // purpose: the gap between them is the mark's diagonal accent.
  static final Path _shape = _buildShape();
  static final Rect _bounds = _shape.getBounds();

  static Path _buildShape() {
    final path = Path()
      ..moveTo(311.402, 0)
      ..lineTo(6.90249, 0)
      ..cubicTo(6.90249, 0, 1.40249, 0, 0.402494, 3.5)
      ..cubicTo(-0.597506, 7, 0.402711, 10.5, 1.90249, 12.5)
      ..cubicTo(3.40228, 14.5, 70.4025, 100.5, 70.4025, 100.5)
      ..cubicTo(70.4025, 100.5, 73.4025, 103.5, 75.4025, 105)
      ..cubicTo(77.4025, 106.5, 81.9025, 106.5, 81.9025, 106.5)
      ..lineTo(159.402, 106.5)
      ..cubicTo(159.402, 106.5, 168.402, 106.5, 172.902, 109)
      ..cubicTo(177.402, 111.5, 179.402, 118.5, 180.902, 119)
      ..cubicTo(182.402, 119.5, 311.402, 0, 311.402, 0)
      ..close();

    path.addPath(
      Path()
        ..moveTo(466.402, 0)
        ..lineTo(351.902, 0)
        ..lineTo(180.902, 159)
        ..lineTo(180.902, 340)
        ..cubicTo(180.902, 342, 181.9, 344.5, 183.4, 345.5)
        ..cubicTo(184.9, 346.5, 184.9, 346.5, 187.902, 348.5)
        ..cubicTo(190.905, 350.5, 277.905, 405, 281.402, 407)
        ..cubicTo(284.9, 409, 287.402, 409.5, 289.4, 408.5)
        ..cubicTo(291.398, 407.5, 291.9, 405.5, 291.902, 402)
        ..cubicTo(291.905, 398.5, 291.905, 123, 291.902, 116.5)
        ..cubicTo(291.9, 110, 297.4, 107.5, 297.4, 107.5)
        ..cubicTo(297.4, 107.5, 299.405, 106.5, 305.402, 106.5)
        ..lineTo(385.4, 106.5)
        ..cubicTo(385.979, 106.5, 396.4, 106, 397.577, 105.288)
        ..cubicTo(398.028, 105.016, 399.423, 103.977, 399.9, 103.5)
        ..cubicTo(400.9, 102.5, 405.9, 96.5, 405.9, 96.5)
        ..lineTo(472.902, 11.5)
        ..cubicTo(472.902, 11.5, 472.9, 6, 472.902, 5)
        ..cubicTo(472.905, 4, 472.9, 2.99999, 471.4, 1.49999)
        ..cubicTo(469.9, 0, 467.9, 0, 466.402, 0)
        ..close(),
      Offset.zero,
    );
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / _bounds.width, size.height / _bounds.height);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(1 + 0.02 * pulse);
    canvas.scale(scale * 0.92);
    canvas.translate(-_bounds.center.dx, -_bounds.center.dy);

    canvas.drawPath(
      _shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, colorDim],
        ).createShader(_bounds),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_MonogramGlyphPainter old) =>
      old.pulse != pulse || old.color != color || old.colorDim != colorDim;
}
