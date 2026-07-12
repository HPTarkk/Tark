import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/tark_mark.dart';
import '../../../../core/widget/ticker_text.dart';

/// The persistent brand emblem that glides through every onboarding beat:
/// a breathing glass-style disc carrying the TARK mark, wrapped in a
/// slowly rotating shimmer halo with a comet orbiting it — the scene's
/// continuously alive centerpiece — plus broadcast ripples that only
/// radiate while [ripplesVisible] (the welcome beat).
///
/// [kick] is the transition accent: drive it 0→1 on a beat change and the
/// disc blips up in scale while a single burst ring escapes it, in sync
/// with the mesh wave the page fires at the same moment.
///
/// Stateless on purpose — the page owns the clocks (all values in 0..1) so
/// the emblem stays perfectly in sync with the rest of the scene while it
/// morphs size via the page's [TweenAnimationBuilder].
class OnboardingEmblem extends StatelessWidget {
  final double size;
  final double breath;
  final double ripple;

  /// 0..1 slow ambient loop driving the halo shimmer rotation and the
  /// comet's orbit phase.
  final double spin;

  /// 0..1 one-shot fired on beat transitions (0 or 1 = at rest).
  final double kick;

  /// 0..1 gate for the ripple layer, animated by the page so the rings
  /// dissolve while the emblem shrinks out of the welcome beat.
  final double ripplesVisible;

  const OnboardingEmblem({
    super.key,
    required this.size,
    required this.breath,
    required this.ripple,
    required this.spin,
    required this.kick,
    required this.ripplesVisible,
  });

  @override
  Widget build(BuildContext context) {
    // Ripples/halo/burst need room beyond the disc; painters use this pad.
    final canvas = size * 2.2;
    final kicking = kick > 0 && kick < 1;
    final blip = kicking ? 1 + 0.07 * sin(pi * kick) : 1.0;
    return SizedBox(
      width: canvas,
      height: canvas,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (ripplesVisible > 0.01)
            CustomPaint(
              size: Size.square(canvas),
              painter: _RipplePainter(
                t: ripple,
                gate: ripplesVisible,
                discRadius: size / 2,
                color: AppColors.amber,
              ),
            ),
          CustomPaint(
            size: Size.square(canvas),
            painter: _HaloCometPainter(
              spin: spin,
              breath: breath,
              radius: size * 0.62,
              color: AppColors.amber,
            ),
          ),
          if (kicking)
            CustomPaint(
              size: Size.square(canvas),
              painter: _BurstPainter(
                t: kick,
                discRadius: size / 2,
                color: AppColors.amber,
              ),
            ),
          Transform.scale(
            scale: blip,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.card,
                border: Border.all(
                  color: AppColors.amber.withAlpha((80 + 80 * breath).toInt()),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.amber.withAlpha(
                      (30 + 60 * breath).toInt(),
                    ),
                    blurRadius: 24 + 12 * breath,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Center(
                child: TarkMark(
                  size: size * 0.52,
                  pulse: breath,
                  color: AppColors.amber,
                  colorDim: AppColors.amberDim,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The emblem's continuous life: a thin ring whose brightness rotates
/// around it (sweep-gradient shimmer) and a comet — bright head, gradient
/// tail — orbiting a touch outside it. Same visual language as the splash
/// halo, scaled down to an ornament.
class _HaloCometPainter extends CustomPainter {
  final double spin;
  final double breath;
  final double radius;
  final Color color;

  const _HaloCometPainter({
    required this.spin,
    required this.breath,
    required this.radius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = SweepGradient(
          colors: [
            color.withAlpha(14),
            color.withAlpha((90 + 50 * breath).toInt()),
            color.withAlpha(14),
          ],
          transform: GradientRotation(2 * pi * spin),
        ).createShader(rect),
    );

    // Comet: orbits faster than the shimmer rotates, so the two never read
    // as one rigid piece.
    final head = 2 * pi * ((spin * 3) % 1.0) - pi / 2;
    const tail = 1.1;
    canvas.drawArc(
      rect,
      head - tail,
      tail,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: tail,
          colors: [color.withAlpha(0), color.withAlpha(170)],
          transform: GradientRotation(head - tail),
        ).createShader(rect),
    );
    final headPos = center + Offset(cos(head), sin(head)) * radius;
    canvas.drawCircle(
      headPos,
      2.6,
      Paint()
        ..color = color.withAlpha(210)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  @override
  bool shouldRepaint(_HaloCometPainter old) =>
      old.spin != spin ||
      old.breath != breath ||
      old.radius != radius ||
      old.color != color;
}

/// One ring escaping the disc on a beat transition — the visible "key-up"
/// that the mesh wave then carries across the whole backdrop.
class _BurstPainter extends CustomPainter {
  final double t;
  final double discRadius;
  final Color color;

  const _BurstPainter({
    required this.t,
    required this.discRadius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final eased = Curves.easeOut.transform(t);
    final radius = discRadius + (size.width / 2 - discRadius) * eased;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = color.withAlpha(((1 - t) * (1 - t) * 120).toInt()),
    );
  }

  @override
  bool shouldRepaint(_BurstPainter old) =>
      old.t != t || old.discRadius != discRadius || old.color != color;
}

/// Three staggered rings expanding from the disc edge and fading out —
/// the same "keyed-up transmitter" motif as the splash emblem.
class _RipplePainter extends CustomPainter {
  final double t;
  final double gate;
  final double discRadius;
  final Color color;

  const _RipplePainter({
    required this.t,
    required this.gate,
    required this.discRadius,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxTravel = size.width / 2 - discRadius;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    for (var i = 0; i < 3; i++) {
      final f = (t + i / 3) % 1.0;
      final radius = discRadius + maxTravel * Curves.easeOut.transform(f);
      final alpha = ((1 - f) * (1 - f) * 80 * gate).toInt();
      if (alpha <= 2) continue;
      canvas.drawCircle(center, radius, paint..color = color.withAlpha(alpha));
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.t != t ||
      old.gate != gate ||
      old.discRadius != discRadius ||
      old.color != color;
}

/// Gamified journey progress styled as a radio signal-strength meter: one
/// ascending bar per beat lights up as the user gets closer to being on air,
/// with a ticking "SIGNAL n%" readout underneath. Each newly earned bar pops
/// in with an easeOutBack overshoot and a glow — the completion reward.
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
        // Ascending bars read left-to-right in both locales, like every
        // real signal indicator.
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
                color: AppColors.textSecondary.withAlpha(170),
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: isFa ? 0.3 : 2,
              ),
            ),
            const SizedBox(width: 5),
            TickerText(
              text: '${percent.localized(context)}%',
              duration: const Duration(milliseconds: 350),
              style: TextStyle(
                color: AppColors.amber,
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
                color: AppColors.textSecondary.withAlpha(60),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            // easeOutBack overshoots past 1 — clamp the fill height but let
            // the overshoot read as the glow flaring, not the bar growing.
            FractionallySizedBox(
              heightFactor: t.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.amber,
                  borderRadius: BorderRadius.circular(2.5),
                  boxShadow: isNewest && t > 0
                      ? [
                          BoxShadow(
                            color: AppColors.amber.withAlpha(
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

/// Shared per-item staggered entrance used inside every beat: fade + rise,
/// same language as the landing/settings entrances. [index] of [count]
/// spreads items across the first 60% of [reveal] so the tail lands early.
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
