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
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Dims the button and ignores taps while the store is being opened.
  final bool busy;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheen.loopUnlessReduced(context);
  }

  @override
  void dispose() {
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
class VersionHop extends StatelessWidget {
  const VersionHop({required this.from, required this.to, super.key});

  final String from;
  final String to;

  @override
  Widget build(BuildContext context) {
    final mono = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.2,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Directionality(
      // Version numbers read left to right in both languages.
      textDirection: TextDirection.ltr,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (from.isNotEmpty) ...[
              Text(
                'v$from'.localized(context),
                style: mono.copyWith(
                  color: AppColors.textSecondary,
                  decoration: TextDecoration.lineThrough,
                  decorationColor: AppColors.textSecondary.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              const _NudgingArrow(),
            ],
            Text(
              'v$to'.localized(context),
              style: mono.copyWith(color: AppColors.amber),
            ),
          ],
        ),
      ),
    );
  }
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
class ReleaseNotes extends StatelessWidget {
  const ReleaseNotes({required this.heading, required this.lines, super.key});

  final String heading;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
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
          for (final line in lines.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsetsDirectional.only(top: 7, end: 10),
                    decoration: BoxDecoration(
                      color: AppColors.amber,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
