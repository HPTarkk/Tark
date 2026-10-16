import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../motion/scene_turn.dart';
import '../theme/app_colors.dart';

/// Small living marks for the states a connection can be stuck in, so a
/// failure or a wait is drawn as what is happening rather than a static
/// icon: the link snapping, the Wi-Fi radio being asked for.

/// Two phones and the link between them: it stretches, snaps in the middle
/// and its two ends spring back towards their phones, settling apart.
class SnappedLinkPainter extends CustomPainter {
  SnappedLinkPainter({
    required this.progress,
    required this.color,
    required this.track,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final mid = size.height / 2;
    const phoneW = 10.0;
    const phoneH = 18.0;
    // The phones lean apart as the link pulls taut.
    final pull = Curves.easeInCubic.transform((t / 0.45).clamp(0.0, 1.0));
    final release = Curves.elasticOut.transform(
      ((t - 0.45) / 0.55).clamp(0.0, 1.0),
    );
    final lean = 2.0 * pull * (1 - release) + 1.0 * release;
    final left = Offset(phoneW / 2 + 1 - lean, mid);
    final right = Offset(size.width - phoneW / 2 - 1 + lean, mid);
    final phone = Paint()
      ..color = track.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final c in [left, right]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: phoneW, height: phoneH),
          const Radius.circular(3),
        ),
        phone,
      );
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final a = Offset(left.dx + phoneW / 2 + 2, mid);
    final b = Offset(right.dx - phoneW / 2 - 2, mid);
    final centre = Offset((a.dx + b.dx) / 2, mid);
    if (t < 0.45) {
      // Taut, thinning, with a tremor at the point that is about to give.
      final shake = 1.2 * pull * math.sin(t * 120);
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(centre.dx, mid + shake, b.dx, b.dy);
      canvas.drawPath(path, line..strokeWidth = 2.2 - 0.9 * pull);
      return;
    }
    // Snapped: each end recoils towards its own phone and curls.
    final gap = 6 + 10 * release;
    final curl = 5 * (1 - release) + 2.5;
    for (final side in [-1.0, 1.0]) {
      final from = side < 0 ? a : b;
      final tip = Offset(centre.dx + side * gap / 2, mid);
      final path = Path()
        ..moveTo(from.dx, from.dy)
        ..quadraticBezierTo(
          (from.dx + tip.dx) / 2,
          mid - curl * side,
          tip.dx,
          tip.dy + curl * 0.6,
        );
      canvas.drawPath(path, line..strokeWidth = 2.0);
    }
    // The spark where it broke, fading.
    final spark = 1 - ((t - 0.45) / 0.3).clamp(0.0, 1.0);
    if (spark > 0) {
      canvas.drawCircle(
        centre,
        2.5 + 4 * (1 - spark),
        Paint()..color = color.withValues(alpha: 0.6 * spark),
      );
    }
  }

  @override
  bool shouldRepaint(SnappedLinkPainter old) =>
      old.color != color || old.track != track;
}

/// A [SnappedLinkPainter] that plays its snap once on appear (settled at
/// once under reduced motion).
class SnappedLinkEmblem extends StatefulWidget {
  const SnappedLinkEmblem({
    this.width = 64,
    this.height = 40,
    this.color,
    super.key,
  });

  final double width;
  final double height;
  final Color? color;

  @override
  State<SnappedLinkEmblem> createState() => _SnappedLinkEmblemState();
}

class _SnappedLinkEmblemState extends State<SnappedLinkEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _snap.value = 1;
    } else if (!_snap.isAnimating && _snap.value == 0) {
      _snap.forward();
    }
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: SnappedLinkPainter(
          progress: _snap,
          color: widget.color ?? AppColors.amber,
          track: AppColors.textSecondary,
        ),
      ),
    ),
  );
}

/// The Wi-Fi mark asking for its radio: the arcs try to light, inner to
/// outer, and fall dark again, round and round, with the slash across them
/// breathing. It is waiting, visibly, for the one switch the person has to
/// flip; the screen moves on by itself the moment the radio is on.
class WifiSeekingEmblem extends StatefulWidget {
  const WifiSeekingEmblem({this.width = 132, this.height = 112, super.key});

  final double width;
  final double height;

  @override
  State<WifiSeekingEmblem> createState() => _WifiSeekingEmblemState();
}

class _WifiSeekingEmblemState extends State<WifiSeekingEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.6);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: widget.width,
      height: widget.height,
      child: CustomPaint(
        painter: WifiSeekingPainter(
          loop: _loop,
          color: AppColors.amber,
          dim: AppColors.textSecondary,
        ),
      ),
    ),
  );
}

class WifiSeekingPainter extends CustomPainter {
  WifiSeekingPainter({
    required this.loop,
    required this.color,
    required this.dim,
  }) : super(repaint: loop);

  final Animation<double> loop;
  final Color color;
  final Color dim;

  @override
  void paint(Canvas canvas, Size size) {
    final t = loop.value;
    final origin = Offset(size.width / 2, size.height * 0.84);
    // A soft halo the arcs sit in.
    canvas.drawCircle(
      origin.translate(0, -size.height * 0.34),
      size.height * 0.5,
      Paint()
        ..shader =
            RadialGradient(
              colors: [
                color.withValues(alpha: 0.16),
                color.withValues(alpha: 0),
              ],
            ).createShader(
              Rect.fromCircle(
                center: origin.translate(0, -size.height * 0.34),
                radius: size.height * 0.5,
              ),
            ),
    );
    canvas.drawCircle(origin, 5, Paint()..color = color);
    for (var i = 0; i < 3; i++) {
      // Each arc lights in turn, holds, and falls dark with the others.
      final on =
          _span(t, 0.1 + i * 0.16, 0.22 + i * 0.16) * (1 - _span(t, 0.72, 0.9));
      final radius = 22.0 + i * 20;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6
        ..color = Color.lerp(
          dim.withValues(alpha: 0.35),
          color,
          Curves.easeOut.transform(on),
        )!;
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: radius),
        -math.pi * 0.78,
        math.pi * 0.56,
        false,
        paint,
      );
    }
    // The slash: there, but not for good.
    final breathe =
        0.55 + 0.45 * (1 - _span(t, 0.1, 0.6)) + 0.45 * _span(t, 0.75, 1);
    final slash = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5
      ..color = color.withValues(alpha: breathe.clamp(0.0, 1.0));
    canvas.drawLine(
      Offset(size.width * 0.22, size.height * 0.08),
      Offset(size.width * 0.78, size.height * 0.9),
      slash,
    );
  }

  @override
  bool shouldRepaint(WifiSeekingPainter old) =>
      old.color != color || old.dim != dim;
}

/// A ring with a light sweeping round it and [icon] at its centre: looking
/// for something, or waiting to be pointed at it. The sweep slows to a calm
/// still under reduced motion.
class ScanSweepEmblem extends StatefulWidget {
  const ScanSweepEmblem({
    required this.icon,
    this.color,
    this.size = 84,
    super.key,
  });

  final IconData icon;
  final Color? color;
  final double size;

  @override
  State<ScanSweepEmblem> createState() => _ScanSweepEmblemState();
}

class _ScanSweepEmblemState extends State<ScanSweepEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.125);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.amber;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _ScanSweepPainter(loop: _loop, color: color),
          child: Center(
            child: AnimatedBuilder(
              animation: _loop,
              builder: (context, child) {
                // The icon brightens as the light passes under it.
                final near = math.cos(_loop.value * 2 * math.pi) * 0.5 + 0.5;
                return Transform.scale(
                  scale: 1 + 0.06 * near,
                  child: Icon(
                    widget.icon,
                    size: widget.size * 0.42,
                    color: Color.lerp(color.withAlpha(170), color, near),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanSweepPainter extends CustomPainter {
  _ScanSweepPainter({required this.loop, required this.color})
    : super(repaint: loop);

  final Animation<double> loop;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 1.5;
    canvas.drawCircle(c, r, Paint()..color = color.withAlpha(18));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withAlpha(70),
    );
    // Inner hairline, breathing.
    final breath = math.sin(loop.value * 2 * math.pi) * 0.5 + 0.5;
    canvas.drawCircle(
      c,
      r * (0.7 + 0.04 * breath),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withAlpha((30 + 40 * breath).round()),
    );
    final start = loop.value * 2 * math.pi - math.pi / 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      start,
      math.pi * 0.7,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: math.pi * 0.7,
          colors: [color.withAlpha(0), color],
          transform: GradientRotation(start),
        ).createShader(rect),
    );
    final head =
        c +
        Offset(
              math.cos(start + math.pi * 0.7),
              math.sin(start + math.pi * 0.7),
            ) *
            r;
    canvas.drawCircle(head, 3.2, Paint()..color = color);
    canvas.drawCircle(
      head,
      7,
      Paint()
        ..color = color.withAlpha(60)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
  }

  @override
  bool shouldRepaint(_ScanSweepPainter old) => old.color != color;
}

double _span(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);

/// A whole state of a screen drawn round a living emblem: the emblem, a
/// title, a line of detail and the way forward, each re-flowing in when the
/// state turns into view ([SceneReflow]). For the screens that used to be an
/// icon over a sentence.
class StatePanel extends StatelessWidget {
  const StatePanel({
    required this.emblem,
    required this.title,
    this.detail,
    this.actions = const [],
    this.scrollable = true,
    super.key,
  });

  /// False where the screen around it already scrolls.
  final bool scrollable;
  final Widget emblem;
  final String title;
  final String? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    var line = 0;
    const padding = EdgeInsets.symmetric(horizontal: 28, vertical: 24);
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SceneReflow(
            index: line++,
            child: Center(child: emblem),
          ),
          const SizedBox(height: 22),
          SceneReflow(
            index: line++,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                height: 1.3,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (detail != null) ...[
            const SizedBox(height: 8),
            SceneReflow(
              index: line++,
              child: Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13.5,
                  height: 1.5,
                ),
              ),
            ),
          ],
          if (actions.isNotEmpty) const SizedBox(height: 24),
          for (final action in actions)
            SceneReflow(
              index: line++,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: action,
              ),
            ),
        ],
      ),
    );
    return Center(
      child: scrollable
          ? SingleChildScrollView(padding: padding, child: body)
          : Padding(padding: padding, child: body),
    );
  }
}

/// The app's wait: a ring with a light running round it and the voice mark
/// at its centre, in place of a bare spinner. Under reduced motion it holds
/// a calm still.
/// A tick that draws itself once inside a soft halo: something finished
/// well. Drawn whole at once under reduced motion.
class SettledEmblem extends StatefulWidget {
  const SettledEmblem({this.size = 88, this.color, super.key});

  final double size;
  final Color? color;

  @override
  State<SettledEmblem> createState() => _SettledEmblemState();
}

class _SettledEmblemState extends State<SettledEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _draw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _draw.value = 1;
    } else if (!_draw.isAnimating && _draw.value == 0) {
      _draw.forward();
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _SettledPainter(
          draw: _draw,
          color: widget.color ?? AppColors.green,
        ),
      ),
    ),
  );
}

class _SettledPainter extends CustomPainter {
  _SettledPainter({required this.draw, required this.color})
    : super(repaint: draw);

  final Animation<double> draw;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = draw.value;
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    final ring = Curves.easeOutCubic.transform(_span(t, 0, 0.55));
    canvas.drawCircle(
      c,
      r * (0.86 + 0.14 * ring),
      Paint()..color = color.withAlpha((26 * ring).round()),
    );
    final rect = Rect.fromCircle(center: c, radius: r * 0.86);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * ring,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color.withAlpha(150),
    );
    final tick = Curves.easeOutBack.transform(_span(t, 0.45, 1));
    if (tick <= 0) return;
    final a = c + Offset(-r * 0.3, r * 0.02);
    final b = c + Offset(-r * 0.08, r * 0.24);
    final d = c + Offset(r * 0.34, -r * 0.22);
    final path = Path()..moveTo(a.dx, a.dy);
    final first = (tick / 0.4).clamp(0.0, 1.0);
    path.lineTo(a.dx + (b.dx - a.dx) * first, a.dy + (b.dy - a.dy) * first);
    if (tick > 0.4) {
      final second = ((tick - 0.4) / 0.6).clamp(0.0, 1.2);
      path.lineTo(b.dx + (d.dx - b.dx) * second, b.dy + (d.dy - b.dy) * second);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SettledPainter old) => old.color != color;
}

class SignalLoader extends StatelessWidget {
  const SignalLoader({this.size = 56, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: Localizations.of<MaterialLocalizations>(
      context,
      MaterialLocalizations,
    )?.refreshIndicatorSemanticLabel,
    child: ScanSweepEmblem(icon: Icons.graphic_eq_rounded, size: size),
  );
}
