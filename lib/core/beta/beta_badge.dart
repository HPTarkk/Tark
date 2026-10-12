import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import 'beta_style.dart';

// The Beta mark, in the three sizes the product needs.
//
// * [BetaBadge] — the headline mark for a screen that *is* a beta feature
//   (an app bar, a page header). Alive: a glass sheen sweeps across it every
//   few seconds and two bubbles rise out of the flask. Use at most one per
//   screen; two things breathing at once is noise.
// * [BetaPill] — the inline tag for a row, an option or a chip that *leads
//   to* a beta feature. Same chrome, smaller, and its sheen plays once as it
//   arrives, then it rests.
// * [BetaMark] — a corner dot for icon-only spots too tight for a word, such
//   as a segmented control. It carries the gradient and the flask; the label
//   travels in its semantics.
//
// All three share the same gradient chrome ([BetaStyle]) and pop in on a
// small overshoot, so the family reads as one thing at every size. Under
// reduced motion they keep their fade and drop the travel, sheen and bubbles.

// ── Headline badge ──────────────────────────────────────────────────────────

class BetaBadge extends StatefulWidget {
  const BetaBadge({this.animate = true, super.key});

  /// Turns the ambient sheen and bubbles off — for a badge that has to sit
  /// beside something else that is already moving.
  final bool animate;

  @override
  State<BetaBadge> createState() => _BetaBadgeState();
}

class _BetaBadgeState extends State<BetaBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _cycle = AnimationController(
    vsync: this,
    duration: BetaStyle.cycle,
  );
  late final Animation<double> _sheen = CurvedAnimation(
    parent: _cycle,
    curve: const Interval(0, BetaStyle.sheenShare, curve: AppMotion.easeInOut),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop();
  }

  @override
  void didUpdateWidget(BetaBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncLoop();
  }

  void _syncLoop() {
    if (widget.animate) {
      _cycle.loopUnlessReduced(context);
    } else {
      _cycle
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _cycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BetaChrome(
    height: 22,
    radius: 11,
    horizontalPadding: 9,
    iconSize: 12,
    fontSize: 9.5,
    sheen: _sheen,
    bubbles: _cycle,
  );
}

// ── Inline pill ─────────────────────────────────────────────────────────────

class BetaPill extends StatefulWidget {
  const BetaPill({this.showIcon = true, super.key});

  /// Drop the flask where the row already has its own leading glyph and a
  /// second icon would crowd it.
  final bool showIcon;

  @override
  State<BetaPill> createState() => _BetaPillState();
}

class _BetaPillState extends State<BetaPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _once = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  late final Animation<double> _sheen = CurvedAnimation(
    parent: _once,
    curve: const Interval(0.25, 1, curve: AppMotion.easeInOut),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // One glint as the pill lands, after the pop has settled — the eye is
    // drawn to it exactly once, then it is just part of the row.
    if (!AppMotion.reduced(context)) unawaited(_once.forward());
  }

  @override
  void dispose() {
    _once.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BetaChrome(
    height: 17,
    radius: 8.5,
    horizontalPadding: 6,
    iconSize: widget.showIcon ? 9.5 : null,
    fontSize: 8,
    sheen: _sheen,
  );
}

// ── Corner mark ─────────────────────────────────────────────────────────────

class BetaMark extends StatelessWidget {
  const BetaMark({this.size = 13, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.getString.beta_semantics,
    excludeSemantics: true,
    child: _Pop(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: BetaStyle.gradient(),
          boxShadow: [
            BoxShadow(
              color: BetaStyle.violet.withValues(alpha: 0.35),
              blurRadius: 6,
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.science_rounded,
          size: size * 0.66,
          color: Colors.white,
        ),
      ),
    ),
  );
}

// ── Shared chrome ───────────────────────────────────────────────────────────

class _BetaChrome extends StatelessWidget {
  const _BetaChrome({
    required this.height,
    required this.radius,
    required this.horizontalPadding,
    required this.iconSize,
    required this.fontSize,
    required this.sheen,
    this.bubbles,
  });

  final double height;
  final double radius;
  final double horizontalPadding;
  final double? iconSize;
  final double fontSize;
  final Animation<double> sheen;
  final Animation<double>? bubbles;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final label = s.beta_label;
    // Tracking spreads Latin capitals into a crisp tag; on Persian it pulls
    // the joined letters apart, so it applies to ASCII labels only.
    final tracked = RegExp(r'^[\x00-\x7F]+$').hasMatch(label);
    final ink = BetaStyle.ink;
    final icon = iconSize;
    return Semantics(
      label: s.beta_semantics,
      excludeSemantics: true,
      child: _Pop(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _ChromePainter(sheen: sheen, radius: radius),
            child: SizedBox(
              height: height,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      _Flask(size: icon, color: ink, bubbles: bubbles),
                      SizedBox(width: icon * 0.3),
                    ],
                    Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        color: ink,
                        fontSize: fontSize,
                        // Even leading centres Latin capitals and Persian
                        // letters alike against the flask; a bare height of 1
                        // left "BETA" riding high in Vazirmatn's tall em box.
                        height: 1.2,
                        leadingDistribution: TextLeadingDistribution.even,
                        fontWeight: FontWeight.w800,
                        letterSpacing: tracked ? fontSize * 0.16 : 0,
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
}

/// The gradient wash, the gradient hairline and the travelling sheen — all in
/// one painter, so a looping badge repaints a single small layer per frame
/// and never rebuilds a widget.
class _ChromePainter extends CustomPainter {
  _ChromePainter({required this.sheen, required this.radius})
    : super(repaint: sheen);

  final Animation<double> sheen;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(
      rrect,
      Paint()..shader = BetaStyle.wash(alpha: 0.16).createShader(rect),
    );

    final t = sheen.value;
    if (t > 0 && t < 1) {
      // A diagonal band of light crossing left to right, entering and leaving
      // fully outside the pill so it never pops in at an edge.
      final centre = -0.3 + 1.6 * t;
      final glow = BetaStyle.sheen;
      canvas
        ..save()
        ..clipRRect(rrect)
        ..drawRect(
          rect,
          Paint()
            ..shader = LinearGradient(
              begin: const Alignment(-1, -0.7),
              end: const Alignment(1, 0.7),
              colors: [
                glow.withValues(alpha: 0),
                glow.withValues(alpha: 0.42),
                glow.withValues(alpha: 0),
              ],
              stops: [
                (centre - 0.16).clamp(0.0, 1.0),
                centre.clamp(0.0, 1.0),
                (centre + 0.16).clamp(0.0, 1.0),
              ],
            ).createShader(rect),
        )
        ..restore();
    }

    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = BetaStyle.gradient(alpha: 0.85).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_ChromePainter old) =>
      old.sheen != sheen || old.radius != radius;
}

/// The flask glyph, with two bubbles rising out of its neck when [bubbles]
/// is running. The bubbles are what turn "a science icon" into "something
/// is brewing" — the whole metaphor in two dots.
class _Flask extends StatelessWidget {
  const _Flask({required this.size, required this.color, this.bubbles});

  final double size;
  final Color color;
  final Animation<double>? bubbles;

  @override
  Widget build(BuildContext context) {
    final glyph = Icon(Icons.science_rounded, size: size, color: color);
    final b = bubbles;
    if (b == null) return glyph;
    return CustomPaint(
      foregroundPainter: BetaBubblePainter(progress: b, color: color),
      child: glyph,
    );
  }
}

/// Bubbles rising out of a flask glyph laid out in the painted box. Shared by
/// the badge and the intro sheet's emblem so the two brew the same way.
class BetaBubblePainter extends CustomPainter {
  BetaBubblePainter({
    required this.progress,
    required this.color,
    this.count = 2,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  /// 2 for a badge; the emblem can afford a third.
  final int count;

  @override
  void paint(Canvas canvas, Size size) {
    // Each bubble owns a slice of the cycle; outside it, nothing is drawn.
    _bubble(canvas, size, start: 0.30, end: 0.62, dx: -0.10, r: 0.085);
    _bubble(canvas, size, start: 0.42, end: 0.80, dx: 0.14, r: 0.065);
    if (count > 2) {
      _bubble(canvas, size, start: 0.58, end: 0.96, dx: -0.02, r: 0.055);
    }
  }

  void _bubble(
    Canvas canvas,
    Size size, {
    required double start,
    required double end,
    required double dx,
    required double r,
  }) {
    final v = progress.value;
    if (v <= start || v >= end) return;
    final t = (v - start) / (end - start);
    final eased = AppMotion.easeOut.transform(t);
    // Rise from the flask's neck to just above the glyph, drifting a touch
    // sideways, fading as it goes — a bubble, not a projectile.
    final centre = Offset(
      size.width * (0.5 + dx * eased),
      size.height * (0.18 - 0.55 * eased),
    );
    final alpha = (t < 0.2 ? t / 0.2 : 1 - (t - 0.2) / 0.8).clamp(0.0, 1.0);
    canvas.drawCircle(
      centre,
      size.width * r * (0.7 + 0.5 * eased),
      Paint()..color = color.withValues(alpha: 0.9 * alpha),
    );
  }

  @override
  bool shouldRepaint(BetaBubblePainter old) =>
      old.progress != progress || old.color != color || old.count != count;
}

/// Arrival for every member of the family: a small overshoot, like a sticker
/// pressed onto the surface. Reduced motion keeps only the fade.
class _Pop extends StatelessWidget {
  const _Pop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 460),
      curve: Curves.easeOutBack,
      child: child,
      builder: (context, v, child) {
        final opacity = v.clamp(0.0, 1.0);
        final faded = Opacity(opacity: opacity, child: child);
        if (reduced) return faded;
        return Transform.scale(scale: 0.72 + 0.28 * v, child: faded);
      },
    );
  }
}
