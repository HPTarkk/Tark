import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';

/// The key the user keeps pressing through the journey.
///
/// It is one physical control for the whole of it: only its words change,
/// and they change the way the website swaps a line of text — the old words
/// lift a few pixels and dissolve, the new ones rise into place — so pressing
/// it reads as the same key moving you along rather than a new button per
/// screen. The arrow leans forward under the finger (mirrored in RTL).
class OnboardingPrimaryButton extends StatefulWidget {
  const OnboardingPrimaryButton({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.breathing = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  /// A slow glow for the one moment the key is the only thing to do.
  final bool breathing;

  @override
  State<OnboardingPrimaryButton> createState() =>
      _OnboardingPrimaryButtonState();
}

class _OnboardingPrimaryButtonState extends State<OnboardingPrimaryButton> {
  bool _down = false;

  static final _radius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final ink = AppColors.background;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final label = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: _SwappingText(
            text: widget.label,
            style: TextStyle(
              color: ink,
              fontSize: 15.5,
              fontWeight: FontWeight.w800,
              letterSpacing: isFa ? 0 : 1.4,
            ),
          ),
        ),
        const SizedBox(width: 10),
        AnimatedSlide(
          // Nudges the way the arrow points — towards the reading end, which
          // is left in Persian, where the icon itself is mirrored.
          offset: Offset(
            _down && !reduced
                ? 0.22 * AppMotion.forwardSign(Directionality.of(context))
                : 0,
            0,
          ),
          duration: AppMotion.press,
          curve: AppMotion.easeOut,
          child: Icon(Icons.arrow_forward_rounded, color: ink, size: 20),
        ),
      ],
    );
    final key = Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: widget.enabled ? 1 : 0.42,
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        child: IgnorePointer(
          ignoring: !widget.enabled,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) {
              HapticFeedback.selectionClick();
              setState(() => _down = true);
            },
            onTapUp: (_) => setState(() => _down = false),
            onTapCancel: () => setState(() => _down = false),
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _down ? 0.97 : 1,
              duration: AppMotion.press,
              curve: AppMotion.easeOut,
              child: Container(
                height: 58,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  borderRadius: _radius,
                  gradient: LinearGradient(
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                    colors: [
                      Color.lerp(AppColors.amber, Colors.white, 0.08)!,
                      AppColors.amber,
                      AppColors.amberDim,
                    ],
                    stops: const [0, 0.55, 1],
                  ),
                ),
                child: label,
              ),
            ),
          ),
        ),
      ),
    );
    return PulseGlow(
      enabled: widget.breathing && widget.enabled,
      borderRadius: _radius,
      child: key,
    );
  }
}

/// A line of text that changes the way the website's text does.
class _SwappingText extends StatelessWidget {
  const _SwappingText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      layoutBuilder: (current, previous) =>
          Stack(alignment: Alignment.center, children: [...previous, ?current]),
      transitionBuilder: (child, animation) {
        final fade = FadeTransition(opacity: animation, child: child);
        if (reduced) return fade;
        final entering = child.key == ValueKey(text);
        return SlideTransition(
          position: Tween<Offset>(
            begin: Offset(0, entering ? 0.32 : -0.24),
            end: Offset.zero,
          ).animate(animation),
          child: fade,
        );
      },
      child: Text(
        text,
        key: ValueKey(text),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

/// The small, quiet way out — "later", "skip".
class OnboardingQuietLink extends StatelessWidget {
  const OnboardingQuietLink({
    required this.label,
    required this.onTap,
    this.uppercase = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final bool uppercase;

  @override
  Widget build(BuildContext context) {
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Semantics(
      button: true,
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          // A quiet link is still a 44dp target: the padding is the control.
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: uppercase ? 11.5 : 13.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: uppercase && !isFa ? 1.5 : 0,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where you are in the journey: three stations on one line, the line
/// filling in as you go — the same "route between two endpoints" the
/// website's loader draws.
class OnboardingProgress extends StatelessWidget {
  const OnboardingProgress({
    required this.step,
    required this.count,
    super.key,
  });

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return Semantics(
      label: context.getString.onbx_progress(
        (step + 1).localized(context),
        count.localized(context),
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: step.toDouble()),
        duration: reduced ? Duration.zero : const Duration(milliseconds: 700),
        curve: AppMotion.easeInOut,
        builder: (context, value, _) => CustomPaint(
          size: Size(22.0 * (count - 1) + 14, 14),
          painter: _ProgressPainter(
            value: value,
            count: count,
            rtl: Directionality.of(context) == TextDirection.rtl,
            accent: AppColors.amber,
            line: AppColors.border,
            fill: AppColors.background,
          ),
        ),
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter({
    required this.value,
    required this.count,
    required this.rtl,
    required this.accent,
    required this.line,
    required this.fill,
  });

  final double value;
  final int count;
  final bool rtl;
  final Color accent;
  final Color line;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final gap = (size.width - 14) / math.max(1, count - 1);
    double x(double i) => rtl ? size.width - 7 - i * gap : 7 + i * gap;
    final pen = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    pen.color = line;
    canvas.drawLine(Offset(x(0), y), Offset(x(count - 1.0), y), pen);
    pen.color = accent;
    canvas.drawLine(Offset(x(0), y), Offset(x(value), y), pen);
    for (var i = 0; i < count; i++) {
      final reached = (value - i).clamp(0.0, 1.0);
      final at = (1 - (value - i).abs()).clamp(0.0, 1.0);
      final center = Offset(x(i.toDouble()), y);
      canvas.drawCircle(
        center,
        4 + 2 * at,
        Paint()..color = Color.lerp(fill, accent, reached > 0 ? 1 : 0)!,
      );
      canvas.drawCircle(
        center,
        4 + 2 * at,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Color.lerp(line, accent, value >= i - 0.001 ? 1 : 0)!,
      );
      if (at > 0) {
        canvas.drawCircle(
          center,
          1.6 * at,
          Paint()..color = fill.withValues(alpha: at),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ProgressPainter old) =>
      old.value != value ||
      old.count != count ||
      old.rtl != rtl ||
      old.accent != accent ||
      old.line != line ||
      old.fill != fill;
}
