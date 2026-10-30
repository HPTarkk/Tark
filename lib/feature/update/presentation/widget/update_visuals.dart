import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';

/// The update prompt's mark: a transmitter disc with radio waves rolling out
/// of both sides — a new version going out over the air.
///
/// One ambient loop drives the waves; the disc itself only breathes. Painted
/// with plain strokes (no blur, no shader mask) so it holds its frame rate on
/// the low-end floor, and isolated in a [RepaintBoundary] so the loop never
/// dirties the card around it.
class BroadcastEmblem extends StatefulWidget {
  const BroadcastEmblem({this.size = 112, this.icon, super.key});

  final double size;
  final IconData? icon;

  @override
  State<BroadcastEmblem> createState() => _BroadcastEmblemState();
}

class _BroadcastEmblemState extends State<BroadcastEmblem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resting at 0.55 leaves each wave mid-flight, which reads as a still
    // broadcast rather than an empty one.
    _loop.loopUnlessReduced(context, rest: 0.55);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final disc = widget.size * 0.42;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size * 1.9,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _WavesPainter(progress: _loop, color: amber),
              ),
            ),
            AnimatedBuilder(
              animation: _loop,
              // Breathes twice per wave cycle — slow enough to read as
              // "powered", not as a warning light.
              builder: (context, child) => Transform.scale(
                scale: 1 + 0.035 * math.sin(_loop.value * 4 * math.pi),
                child: child,
              ),
              child: Container(
                width: disc,
                height: disc,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [amber, AppColors.amberDim],
                    center: const Alignment(-0.3, -0.35),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: amber.withValues(alpha: 0.35),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  widget.icon ?? Icons.arrow_upward_rounded,
                  color: AppColors.background,
                  size: disc * 0.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WavesPainter extends CustomPainter {
  _WavesPainter({required this.progress, required this.color})
    : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  static const _waves = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final minR = size.height * 0.30;
    final maxR = size.height * 0.92;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < _waves; i++) {
      // Each wave is the same wave a third of a cycle later.
      final t = (progress.value + i / _waves) % 1.0;
      final r = minR + (maxR - minR) * t;
      // In quickly, out slowly: a wave is brightest just after it leaves.
      final alpha = (t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85) * 0.85;
      paint
        ..color = color.withValues(alpha: alpha.clamp(0, 1))
        ..strokeWidth = 3.2 - 1.6 * t;
      final rect = Rect.fromCircle(center: center, radius: r);
      const sweep = math.pi * 0.42;
      canvas.drawArc(rect, -sweep / 2, sweep, false, paint);
      canvas.drawArc(rect, math.pi - sweep / 2, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(_WavesPainter old) => old.color != color;
}

/// The one filled button in the update prompt: solid amber with a highlight
/// that sweeps across it every few seconds, so the eye lands on it without
/// the whole card having to move.
class SheenButton extends StatefulWidget {
  const SheenButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.busy = false,
    this.startAfter,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Dims the button and ignores taps while the store is being opened.
  final bool busy;

  /// Holds the first glint until this completes, so it crosses the button
  /// the moment the button lands instead of while it is still invisible.
  final Animation<double>? startAfter;

  @override
  State<SheenButton> createState() => _SheenButtonState();
}

class _SheenButtonState extends State<SheenButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );

  @override
  void initState() {
    super.initState();
    widget.startAfter?.addStatusListener(_onArrival);
  }

  bool get _held => widget.startAfter?.isCompleted == false;

  void _onArrival(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    widget.startAfter?.removeStatusListener(_onArrival);
    _sheen.loopUnlessReduced(context);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_held) _sheen.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    widget.startAfter?.removeStatusListener(_onArrival);
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(16);
    final onAmber = AppColors.background;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: widget.busy ? null : widget.onTap,
        borderRadius: radius,
        child: AnimatedOpacity(
          duration: AppMotion.chip,
          opacity: widget.busy ? 0.6 : 1,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SheenPainter(
                progress: _sheen,
                color: AppColors.amber,
                radius: 16,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, size: 20, color: onAmber),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: onAmber,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
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
}

class _SheenPainter extends CustomPainter {
  _SheenPainter({
    required this.progress,
    required this.color,
    required this.radius,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas.drawRRect(rrect, Paint()..color = color);

    // The sweep occupies the first 40% of each cycle and rests for the rest,
    // so it reads as a glint rather than a conveyor belt.
    final t = progress.value / 0.4;
    if (t >= 1) return;
    final band = size.width * 0.35;
    final x = -band + (size.width + band * 2) * Curves.easeInOut.transform(t);
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(
      Rect.fromLTWH(x - band, 0, band * 2, size.height),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: 0.32),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(x - band, 0, band * 2, size.height)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.color != color || old.radius != radius;
}

/// "1.0.21 → 1.0.22": the installed version dimmed, the new one lit, and the
/// arrow between them nudging forward.
///
/// Given an [arrival], the hop plays out instead of simply being there: the
/// chip rises, a strike draws through the installed version, the arrow slides
/// across and the digits that changed roll over like an odometer, the new
/// version landing with a flash of the chip's rim.
class VersionHop extends StatelessWidget {
  const VersionHop({
    required this.from,
    required this.to,
    this.arrival,
    super.key,
  });

  final String from;
  final String to;

  /// 0 → 1 over the hop's whole entrance; null shows it settled.
  final Animation<double>? arrival;

  // Beats of the entrance, as shares of [arrival].
  static const _chip = Interval(0, 0.32, curve: AppMotion.easeOut);
  static const _strike = Interval(0.26, 0.5, curve: AppMotion.easeInOut);
  static const _arrow = Interval(0.34, 0.6, curve: AppMotion.easeOut);
  static const _flash = Interval(0.74, 1, curve: Curves.easeOut);

  /// The roll of the [k]th changed character of [changed], one after another
  /// so the number reads as counting over rather than swapping.
  static Interval _roll(int k, int changed) {
    final step = changed <= 1 ? 0.0 : math.min(0.08, 0.24 / (changed - 1));
    final start = 0.46 + step * k;
    return Interval(start, math.min(1, start + 0.3), curve: Curves.easeOutBack);
  }

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final arrival = this.arrival;
    final reduced = AppMotion.reduced(context);
    final installed = 'v$from'.localized(context);
    final latest = 'v$to'.localized(context);
    final dimmed = mono.copyWith(color: AppColors.textSecondary);
    final lit = mono.copyWith(color: AppColors.amber);

    Widget oldVersion = Text(
      installed,
      style: dimmed.copyWith(
        decoration: arrival == null ? TextDecoration.lineThrough : null,
        decorationColor: AppColors.textSecondary.withValues(alpha: 0.6),
      ),
    );
    Widget arrow = const _NudgingArrow();
    Widget newVersion = Text(latest, style: lit);

    if (arrival != null) {
      final strike = CurvedAnimation(parent: arrival, curve: _strike);
      oldVersion = CustomPaint(
        foregroundPainter: _StrikePainter(
          progress: strike,
          color: AppColors.textSecondary.withValues(alpha: 0.6),
        ),
        child: AnimatedBuilder(
          animation: strike,
          // Lit while it is still the version you have, dimming as the
          // strike crosses it.
          builder: (context, _) => Text(
            installed,
            style: mono.copyWith(
              color: Color.lerp(
                AppColors.textPrimary,
                AppColors.textSecondary,
                strike.value,
              ),
            ),
          ),
        ),
      );
      final slide = CurvedAnimation(parent: arrival, curve: _arrow);
      arrow = FadeTransition(
        opacity: slide,
        child: AnimatedBuilder(
          animation: slide,
          builder: (context, child) => Transform.translate(
            offset: Offset(reduced ? 0 : -8 * (1 - slide.value), 0),
            child: child,
          ),
          child: arrow,
        ),
      );
      newVersion = _Odometer(
        from: from.isEmpty ? latest : installed,
        to: latest,
        style: lit,
        arrival: arrival,
        roll: _roll,
        flash: CurvedAnimation(parent: arrival, curve: _flash),
      );
    }

    Widget chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(40),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (from.isNotEmpty) ...[oldVersion, arrow],
          newVersion,
        ],
      ),
    );

    if (arrival != null) {
      final flash = CurvedAnimation(parent: arrival, curve: _flash);
      final rise = CurvedAnimation(parent: arrival, curve: _chip);
      chip = FadeTransition(
        opacity: rise,
        child: AnimatedBuilder(
          animation: Listenable.merge([rise, flash]),
          builder: (context, child) {
            // The rim catches the light once, as the new version lands:
            // up quickly, back down slowly.
            final f = flash.value;
            final glow = f <= 0 || f >= 1
                ? 0.0
                : (f < 0.25 ? f / 0.25 : 1 - (f - 0.25) / 0.75);
            return Transform.translate(
              offset: Offset(
                0,
                reduced ? 0 : AppMotion.rise * (1 - rise.value),
              ),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(
                    color: AppColors.amber.withValues(alpha: 0.75 * glow),
                    width: 1.4,
                  ),
                ),
                child: child,
              ),
            );
          },
          child: chip,
        ),
      );
    }

    return Semantics(
      label: from.isEmpty ? latest : '$installed → $latest',
      excludeSemantics: arrival != null,
      child: Directionality(
        // Version numbers read left to right in both languages.
        textDirection: TextDirection.ltr,
        child: chip,
      ),
    );
  }
}

/// The strike through the installed version, drawn left to right — the way
/// the number reads in both languages.
class _StrikePainter extends CustomPainter {
  _StrikePainter({required this.progress, required this.color})
    : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value.clamp(0.0, 1.0);
    if (t <= 0) return;
    final y = size.height * 0.54;
    canvas.drawLine(
      Offset(-1, y),
      Offset(-1 + (size.width + 2) * t, y),
      Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StrikePainter old) => old.color != color;
}

/// The new version counting over from the installed one: each character that
/// changed rolls up out of the way as its replacement rises into the slot,
/// the rest hold still. Characters line up from the start, so 1.0.9 → 1.0.10
/// keeps "1.0." fixed and only rolls the tail.
class _Odometer extends StatelessWidget {
  const _Odometer({
    required this.from,
    required this.to,
    required this.style,
    required this.arrival,
    required this.roll,
    required this.flash,
  });

  final String from;
  final String to;
  final TextStyle style;
  final Animation<double> arrival;
  final Interval Function(int k, int changed) roll;
  final Animation<double> flash;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final next = to.characters.toList();
    final prev = from.characters.toList();
    final changed = [
      for (var i = 0; i < next.length; i++)
        if (i >= prev.length || prev[i] != next[i]) i,
    ];
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < next.length; i++)
          if (!changed.contains(i))
            Text(next[i], style: style)
          else
            _RollingChar(
              from: i < prev.length ? prev[i] : '',
              to: next[i],
              style: style,
              progress: CurvedAnimation(
                parent: arrival,
                curve: roll(changed.indexOf(i), changed.length),
              ),
              reduced: reduced,
            ),
      ],
    );
    if (reduced) return row;
    return AnimatedBuilder(
      animation: flash,
      // A small kick as it lands, so the eye goes to the number that matters.
      builder: (context, child) {
        final f = flash.value;
        final kick = f <= 0 || f >= 1 ? 0.0 : math.sin(f * math.pi);
        return Transform.scale(scale: 1 + 0.1 * kick, child: child);
      },
      child: row,
    );
  }
}

class _RollingChar extends StatelessWidget {
  const _RollingChar({
    required this.from,
    required this.to,
    required this.style,
    required this.progress,
    required this.reduced,
  });

  final String from;
  final String to;
  final TextStyle style;
  final Animation<double> progress;
  final bool reduced;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final t = progress.value;
        final settled = t.clamp(0.0, 1.0);
        // Old leaves upward, new rises from below — the same vertical
        // hand-over the rest of the app uses for a value changing in place.
        return Stack(
          alignment: Alignment.center,
          children: [
            if (from.isNotEmpty && settled < 1)
              Opacity(
                opacity: 1 - settled,
                child: FractionalTranslation(
                  translation: Offset(0, reduced ? 0 : -t),
                  child: Text(from, style: style),
                ),
              ),
            Opacity(
              opacity: settled,
              child: FractionalTranslation(
                translation: Offset(0, reduced ? 0 : 1 - t),
                child: Text(to, style: style),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _NudgingArrow extends StatefulWidget {
  const _NudgingArrow();

  @override
  State<_NudgingArrow> createState() => _NudgingArrowState();
}

class _NudgingArrowState extends State<_NudgingArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.loopUnlessReduced(context, reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Transform.translate(
        offset: Offset(3 * AppMotion.easeInOut.transform(_c.value), 0),
        child: child,
      ),
      child: Icon(
        Icons.arrow_forward_rounded,
        size: 15,
        color: AppColors.amber.withValues(alpha: 0.8),
      ),
    ),
  );
}

/// The release notes as a staggered list of amber-ticked lines.
///
/// Given an [arrival], the card rises and then ticks its lines off one by
/// one: each tick spins square into place with a little overshoot, and its
/// line rises in beside it.
class ReleaseNotes extends StatelessWidget {
  const ReleaseNotes({
    required this.heading,
    required this.lines,
    this.arrival,
    super.key,
  });

  final String heading;
  final List<String> lines;

  /// 0 → 1 over the card's whole entrance; null shows it settled.
  final Animation<double>? arrival;

  static const _maxLines = 5;
  static const _card = Interval(0, 0.36, curve: AppMotion.easeOut);

  static Interval _line(int i, int count) {
    final step = count <= 1 ? 0.0 : math.min(0.14, 0.36 / (count - 1));
    final start = 0.22 + step * i;
    return Interval(start, math.min(1, start + 0.42), curve: AppMotion.easeOut);
  }

  static Interval _tick(int i, int count) {
    final line = _line(i, count);
    return Interval(line.begin, line.end, curve: Curves.easeOutBack);
  }

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    final arrival = this.arrival;
    final reduced = AppMotion.reduced(context);
    final shown = lines.take(_maxLines).toList();
    Widget card = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < shown.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _tickMark(
                    arrival == null
                        ? null
                        : CurvedAnimation(
                            parent: arrival,
                            curve: _tick(i, shown.length),
                          ),
                    reduced,
                  ),
                  Expanded(
                    child: _rising(
                      arrival == null
                          ? null
                          : CurvedAnimation(
                              parent: arrival,
                              curve: _line(i, shown.length),
                            ),
                      reduced,
                      Text(
                        shown[i],
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13.5,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (arrival == null) return card;
    return _rising(
      CurvedAnimation(parent: arrival, curve: _card),
      reduced,
      card,
      distance: AppMotion.rise * 1.4,
    );
  }

  static Widget _rising(
    Animation<double>? t,
    bool reduced,
    Widget child, {
    double distance = 8,
  }) {
    if (t == null) return child;
    final faded = FadeTransition(opacity: t, child: child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: t,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, distance * (1 - t.value)),
        child: child,
      ),
      child: faded,
    );
  }

  static Widget _tickMark(Animation<double>? t, bool reduced) {
    const margin = EdgeInsetsDirectional.only(top: 7, end: 10);
    final mark = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    if (t == null) return Padding(padding: margin, child: mark);
    if (reduced) {
      return Padding(
        padding: margin,
        child: FadeTransition(opacity: t, child: mark),
      );
    }
    final spinning = AnimatedBuilder(
      animation: t,
      builder: (context, child) {
        final v = t.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: (1 - v) * math.pi / 2,
            child: Transform.scale(scale: math.max(0, v), child: child),
          ),
        );
      },
      child: mark,
    );
    return Padding(padding: margin, child: spinning);
  }
}
