import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/ticker_text.dart';
import 'onboarding_palette.dart';

/// The onboarding "field-radio console" HUD kit.
///
/// Every interactive surface in the journey is built from these instead of
/// Material widgets, so the controls read as part of the animated world rather
/// than a form bolted on top: cut-corner glass panels with amber hairlines and
/// corner brackets, option rows that light up like console channels, sun/moon
/// mode plates that drive the environmental sky, a terminal-style callsign
/// field, and an angular "transmit key" for the primary action.
///
/// All pieces share [Onb]'s fixed palette and take explicit animation values
/// from the page so they breathe in sync with the scene.

// ── Panel ────────────────────────────────────────────────────────────────────

/// A framed glass console panel: sharp body with a 45°-cut top-right corner,
/// an amber hairline, L-brackets at the corners, and an optional header strip
/// (`▮ LABEL ······ status`). The bevel + brackets are what make it read as a
/// HUD readout rather than a card.
class HudPanel extends StatelessWidget {
  final String? header;
  final String? status;
  final Widget child;
  final EdgeInsets padding;
  final bool accent;

  /// 0..1 ambient glow (usually the page's breath) modulating the frame.
  final double glow;

  const HudPanel({
    super.key,
    required this.child,
    this.header,
    this.status,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
    this.accent = true,
    this.glow = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HudFramePainter(
        cutTR: 16,
        cutBL: 0,
        border: accent
            ? Onb.amber.withAlpha((70 + 60 * glow).toInt())
            : Onb.line,
        fillTop: Onb.panelHi.withAlpha(232),
        fillBottom: Onb.ink.withAlpha(232),
        bracket: accent ? Onb.amber : Onb.textDim,
        glowColor: accent ? Onb.amber.withAlpha((26 * glow).toInt()) : null,
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null) ...[
              _HudHeader(label: header!, status: status),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class _HudHeader extends StatelessWidget {
  final String label;
  final String? status;

  const _HudHeader({required this.label, this.status});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 3, height: 13, color: Onb.amber),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Onb.text,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.5,
            ),
          ),
        ),
        if (status != null)
          Text(
            status!.toUpperCase(),
            style: TextStyle(
              color: Onb.amber.withAlpha(190),
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
      ],
    );
  }
}

// ── Option row ───────────────────────────────────────────────────────────────

/// A selectable console channel: a status lamp, a label (+ optional sub), and
/// a leading glyph. Selecting lights the lamp and outlines the row in glowing
/// amber. No ink ripple — a plain tap, styled by hand.
class HudOption extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final String label;
  final String? sublabel;
  final IconData? icon;
  final double glow;

  /// Compact = a centered pill for side-by-side rows (no SET tag, tighter).
  final bool compact;

  const HudOption({
    super.key,
    required this.selected,
    required this.onTap,
    required this.label,
    this.sublabel,
    this.icon,
    this.glow = 0.5,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: CustomPaint(
        painter: _HudFramePainter(
          cutTR: 10,
          cutBL: 0,
          border: selected
              ? Onb.amber.withAlpha((150 + 80 * glow).toInt())
              : Onb.line,
          fillTop: selected
              ? Onb.amber.withAlpha((18 + 14 * glow).toInt())
              : Onb.panel.withAlpha(150),
          fillBottom: selected
              ? Onb.amber.withAlpha((8 + 8 * glow).toInt())
              : Onb.ink.withAlpha(150),
          bracket: selected ? Onb.amber : Colors.transparent,
          glowColor:
              selected ? Onb.amber.withAlpha((30 * glow).toInt()) : null,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: compact ? 11 : 13,
          ),
          child: Row(
            mainAxisAlignment:
                compact ? MainAxisAlignment.center : MainAxisAlignment.start,
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.max,
            children: [
              _Lamp(on: selected, glow: glow),
              const SizedBox(width: 12),
              if (icon != null) ...[
                Icon(icon, size: 17, color: selected ? Onb.amber : Onb.textDim),
                const SizedBox(width: 10),
              ],
              if (compact)
                _labelBlock(centered: true)
              else
                Expanded(child: _labelBlock(centered: false)),
              if (!compact)
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: selected ? 1 : 0,
                  child: Text(
                    '◂ SET',
                    style: TextStyle(
                      color: Onb.amber.withAlpha((160 + 80 * glow).toInt()),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _labelBlock({required bool centered}) => Column(
    crossAxisAlignment:
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(
          color: selected ? Onb.text : Onb.textDim,
          fontSize: 14,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
      if (sublabel != null)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            sublabel!,
            style: TextStyle(
              color: (selected ? Onb.amber : Onb.textDim).withAlpha(170),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ),
    ],
  );
}

/// The little square status lamp on an option / channel.
class _Lamp extends StatelessWidget {
  final bool on;
  final double glow;

  const _Lamp({required this.on, required this.glow});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: on ? Onb.amber : Colors.transparent,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(
          color: on ? Onb.amber : Onb.textDim.withAlpha(150),
          width: 1.4,
        ),
        boxShadow: on
            ? [
                BoxShadow(
                  color: Onb.amber.withAlpha((150 * glow).toInt()),
                  blurRadius: 8,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

// ── Day / Night mode plates ──────────────────────────────────────────────────

/// The theme control as two environment plates. Picking one drives the scene's
/// sunrise/sunset; the glyphs (rayed sun, craters-and-stars moon) preview what
/// the sky is about to become.
class HudSunMoonTiles extends StatelessWidget {
  final bool night;
  final ValueChanged<bool> onSelect;
  final double glow;

  const HudSunMoonTiles({
    super.key,
    required this.night,
    required this.onSelect,
    this.glow = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Plate(
            selected: !night,
            glow: glow,
            label: 'DAY',
            onTap: () => onSelect(false),
            glyph: _SunGlyph(color: !night ? Onb.amber : Onb.textDim),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Plate(
            selected: night,
            glow: glow,
            label: 'NIGHT',
            onTap: () => onSelect(true),
            glyph: _MoonGlyph(color: night ? Onb.text : Onb.textDim),
          ),
        ),
      ],
    );
  }
}

class _Plate extends StatelessWidget {
  final bool selected;
  final double glow;
  final String label;
  final VoidCallback onTap;
  final Widget glyph;

  const _Plate({
    required this.selected,
    required this.glow,
    required this.label,
    required this.onTap,
    required this.glyph,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: CustomPaint(
        painter: _HudFramePainter(
          cutTR: 12,
          cutBL: 12,
          border: selected
              ? Onb.amber.withAlpha((160 + 70 * glow).toInt())
              : Onb.line,
          fillTop: selected ? Onb.amber.withAlpha(20) : Onb.panel.withAlpha(150),
          fillBottom: Onb.ink.withAlpha(160),
          bracket: selected ? Onb.amber : Colors.transparent,
          glowColor:
              selected ? Onb.amber.withAlpha((34 * glow).toInt()) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              SizedBox(width: 34, height: 34, child: glyph),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? Onb.text : Onb.textDim,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SunGlyph extends StatelessWidget {
  final Color color;
  const _SunGlyph({required this.color});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SunPainter(color), size: const Size.square(34));
}

class _MoonGlyph extends StatelessWidget {
  final Color color;
  const _MoonGlyph({required this.color});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _MoonPainter(color), size: const Size.square(34));
}

class _SunPainter extends CustomPainter {
  final Color color;
  const _SunPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()..color = color;
    canvas.drawCircle(c, size.width * 0.24, p);
    final ray = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a = i * pi / 4;
      final d = Offset(cos(a), sin(a));
      canvas.drawLine(c + d * size.width * 0.34, c + d * size.width * 0.46, ray);
    }
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.color != color;
}

class _MoonPainter extends CustomPainter {
  final Color color;
  const _MoonPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.30;
    // Crescent = disc minus an offset disc.
    final disc = Path()..addOval(Rect.fromCircle(center: c, radius: r));
    final bite = Path()
      ..addOval(Rect.fromCircle(center: c + Offset(r * 0.55, -r * 0.15), radius: r));
    canvas.drawPath(
      Path.combine(PathOperation.difference, disc, bite),
      Paint()..color = color,
    );
    // A couple of tiny stars.
    final s = Paint()..color = color.withAlpha(180);
    canvas.drawCircle(c + Offset(r * 0.9, r * 0.6), 1.3, s);
    canvas.drawCircle(c + Offset(r * 1.15, -r * 0.5), 1, s);
  }

  @override
  bool shouldRepaint(_MoonPainter old) => old.color != color;
}

// ── Callsign field ───────────────────────────────────────────────────────────

/// A terminal-style handle input: a `‹CALLSIGN›` prompt, amber mono text, a
/// block caret, and a HUD frame — no Material underline or fill in sight. Wraps
/// a stripped [TextField] purely for keyboard plumbing.
class HudField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmitted;
  final String prompt;
  final String hint;
  final Widget? trailing;
  final double glow;

  const HudField({
    super.key,
    required this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.prompt = 'CALLSIGN',
    this.hint = 'ENTER HANDLE',
    this.trailing,
    this.glow = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HudFramePainter(
        cutTR: 12,
        cutBL: 0,
        border: Onb.amber.withAlpha((110 + 70 * glow).toInt()),
        fillTop: Onb.ink.withAlpha(220),
        fillBottom: Onb.ink.withAlpha(220),
        bracket: Onb.amber,
        glowColor: Onb.amber.withAlpha((22 * glow).toInt()),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Text(
              '‹$prompt›',
              style: TextStyle(
                color: Onb.amber.withAlpha(160),
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                onChanged: onChanged,
                onSubmitted: (_) => onSubmitted?.call(),
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.characters,
                cursorColor: Onb.amber,
                cursorWidth: 9,
                cursorRadius: const Radius.circular(1),
                style: const TextStyle(
                  color: Onb.amber,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2,
                ),
                decoration: InputDecoration.collapsed(
                  hintText: hint,
                  hintStyle: TextStyle(
                    color: Onb.textDim.withAlpha(120),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// A small square HUD key (e.g. the callsign randomiser). Custom, tappable.
class HudMiniKey extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double glow;

  const HudMiniKey({
    super.key,
    required this.icon,
    required this.onTap,
    this.glow = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: CustomPaint(
        painter: _HudFramePainter(
          cutTR: 8,
          cutBL: 8,
          border: Onb.amber.withAlpha((120 + 60 * glow).toInt()),
          fillTop: Onb.amber.withAlpha(18),
          fillBottom: Onb.ink.withAlpha(160),
          bracket: Colors.transparent,
          glowColor: Onb.amber.withAlpha((22 * glow).toInt()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, size: 18, color: Onb.amber),
        ),
      ),
    );
  }
}

// ── Transmit key (primary CTA) ───────────────────────────────────────────────

/// The primary action, styled as a console "transmit key": a wide bar with
/// twin diagonal cuts, corner brackets, a chevron/▶ glyph, and a periodic
/// gloss sweep. Pulses on the bookend beats. Disabled = dim, no glow.
class HudActionKey extends StatelessWidget {
  final String label;
  final bool enabled;
  final bool pulsing;
  final bool go; // launch variant → green-tinged "on air"
  final VoidCallback? onTap;

  /// 0..1 breath and 0..1 gloss-sweep phase from the page.
  final double glow;
  final double gloss;

  const HudActionKey({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.pulsing = false,
    this.go = false,
    this.glow = 0.5,
    this.gloss = 0,
  });

  @override
  Widget build(BuildContext context) {
    final accent = go ? Onb.green : Onb.amber;
    final glossT = Curves.easeInOut.transform(
      ((gloss - 0.15) / 0.5).clamp(0.0, 1.0),
    );
    final dx = -1.8 + 3.6 * glossT;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: CustomPaint(
        painter: _HudFramePainter(
          cutTR: 16,
          cutBL: 16,
          border: enabled
              ? accent.withAlpha((150 + 90 * (pulsing ? glow : 0.5)).toInt())
              : Onb.line,
          fillTop: enabled ? accent.withAlpha(34) : Onb.panel.withAlpha(120),
          fillBottom: enabled ? accent.withAlpha(14) : Onb.ink.withAlpha(120),
          bracket: enabled ? accent : Onb.textDim,
          glowColor: (enabled && pulsing)
              ? accent.withAlpha((30 + 40 * glow).toInt())
              : (enabled ? accent.withAlpha(18) : null),
        ),
        child: ClipRect(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 17),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Chevron(
                      color: enabled ? accent : Onb.textDim,
                      go: go,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        color: enabled ? accent : Onb.textDim,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
              // Gloss sweep.
              if (enabled)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ShaderMask(
                      blendMode: BlendMode.srcATop,
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment(dx - 0.6, -1),
                        end: Alignment(dx + 0.6, 1),
                        colors: [
                          const Color(0x00FFFFFF),
                          Colors.white.withAlpha(40),
                          const Color(0x00FFFFFF),
                        ],
                      ).createShader(rect),
                      child: Container(color: Colors.white.withAlpha(1)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A double-chevron ▶▶ (or ◉ target for the launch/go variant), hand-painted so
/// it matches the HUD line-weight instead of a Material icon.
class _Chevron extends StatelessWidget {
  final Color color;
  final bool go;
  const _Chevron({required this.color, required this.go});
  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _ChevronPainter(color, go), size: const Size(20, 16));
}

class _ChevronPainter extends CustomPainter {
  final Color color;
  final bool go;
  const _ChevronPainter(this.color, this.go);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c = size.center(Offset.zero);
    if (go) {
      // Broadcast target: ring + center dot.
      canvas.drawCircle(c, size.height * 0.42, p);
      canvas.drawCircle(c, 1.6, Paint()..color = color);
      return;
    }
    void chevron(double x) {
      final path = Path()
        ..moveTo(x, c.dy - size.height * 0.34)
        ..lineTo(x + size.width * 0.28, c.dy)
        ..lineTo(x, c.dy + size.height * 0.34);
      canvas.drawPath(path, p);
    }

    chevron(size.width * 0.18);
    chevron(size.width * 0.44);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color || old.go != go;
}

// ── Shared frame painter ─────────────────────────────────────────────────────

/// Draws the whole HUD surface: a body with up to two 45° corner cuts (top-
/// right, bottom-left), a vertical glass fill, an outer glow, a hairline
/// border, and short L-brackets hugging the square corners. One painter backs
/// every panel, option, plate, field, and key so they share an exact language.
class _HudFramePainter extends CustomPainter {
  final double cutTR;
  final double cutBL;
  final Color border;
  final Color fillTop;
  final Color fillBottom;
  final Color bracket;
  final Color? glowColor;

  const _HudFramePainter({
    required this.cutTR,
    required this.cutBL,
    required this.border,
    required this.fillTop,
    required this.fillBottom,
    required this.bracket,
    this.glowColor,
  });

  Path _bodyPath(Size s) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(s.width - cutTR, 0)
      ..lineTo(s.width, cutTR)
      ..lineTo(s.width, s.height)
      ..lineTo(cutBL, s.height)
      ..lineTo(0, s.height - cutBL)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _bodyPath(size);

    if (glowColor != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = glowColor!
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [fillTop, fillBottom],
        ).createShader(Offset.zero & size),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = border,
    );

    if (bracket.a != 0) {
      final b = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = bracket;
      const len = 9.0;
      // Top-left.
      canvas.drawLine(const Offset(0, 0), const Offset(len, 0), b);
      canvas.drawLine(const Offset(0, 0), const Offset(0, len), b);
      // Bottom-right.
      canvas.drawLine(
        Offset(size.width, size.height),
        Offset(size.width - len, size.height),
        b,
      );
      canvas.drawLine(
        Offset(size.width, size.height),
        Offset(size.width, size.height - len),
        b,
      );
    }
  }

  @override
  bool shouldRepaint(_HudFramePainter old) =>
      old.cutTR != cutTR ||
      old.cutBL != cutBL ||
      old.border != border ||
      old.fillTop != fillTop ||
      old.fillBottom != fillBottom ||
      old.bracket != bracket ||
      old.glowColor != glowColor;
}

// ── Signal-strength progress meter ───────────────────────────────────────────

/// Journey progress styled as a radio signal-strength meter: one ascending bar
/// per beat lights up as the user nears being on air, with a ticking
/// "SIGNAL n%" readout. Each newly earned bar pops in with an easeOutBack
/// overshoot and a glow — the completion reward, alongside the radio building.
class SignalMeter extends StatelessWidget {
  final int step;
  final int stepCount;

  const SignalMeter({super.key, required this.step, required this.stepCount});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final percent = ((step + 1) * 100 / stepCount).round();
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < stepCount; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _SignalBar(
                  height: 8.0 + 12.0 * i / (stepCount - 1),
                  filled: i <= step,
                  isNewest: i == step,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.onboarding_signal,
              style: TextStyle(
                color: Onb.textDim.withAlpha(190),
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: isFa ? 0.3 : 2,
              ),
            ),
            const SizedBox(width: 5),
            TickerText(
              text: '${percent.localized(context)}%',
              duration: const Duration(milliseconds: 350),
              style: const TextStyle(
                color: Onb.amber,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SignalBar extends StatelessWidget {
  final double height;
  final bool filled;
  final bool isNewest;

  const _SignalBar({
    required this.height,
    required this.filled,
    required this.isNewest,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: filled ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 500),
      curve: filled ? Curves.easeOutBack : Curves.easeOut,
      builder: (_, t, _) => SizedBox(
        width: 5,
        height: height,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Onb.textDim.withAlpha(60),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            FractionallySizedBox(
              heightFactor: t.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: Onb.amber,
                  borderRadius: BorderRadius.circular(2.5),
                  boxShadow: isNewest && t > 0
                      ? [
                          BoxShadow(
                            color: Onb.amber.withAlpha(
                              (130 * t.clamp(0.0, 1.0)).toInt(),
                            ),
                            blurRadius: 7,
                            spreadRadius: 0.5,
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared per-item staggered entrance used inside every beat: fade + rise.
/// [index] of [count] spreads items across the first 60% of [reveal] so the
/// tail lands early.
class StaggeredItem extends StatelessWidget {
  final Animation<double> reveal;
  final int index;
  final int count;
  final Widget child;

  const StaggeredItem({
    super.key,
    required this.reveal,
    required this.index,
    required this.count,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final start = count <= 1 ? 0.0 : index * 0.6 / count;
    final anim = CurvedAnimation(
      parent: reveal,
      curve: Interval(start, min(start + 0.4, 1.0), curve: Curves.easeOutCubic),
    );
    return AnimatedBuilder(
      animation: anim,
      child: child,
      builder: (_, prebuilt) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, 22 * (1 - anim.value)),
          child: prebuilt,
        ),
      ),
    );
  }
}
