import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/rating_prompt.dart';
import 'rating_story_sheet.dart';

/// Settings' way to rate Tarkk on Cafe Bazaar, whenever you like.
///
/// One card that is one button, with a star that twinkles and turns now and
/// then: alive enough to be found, quiet enough not to nag. Renders nothing
/// where there is no Bazaar to rate in.
class RateAppCard extends StatefulWidget {
  const RateAppCard({super.key, this.prompt});

  /// A seam for tests; the app uses the shared [RatingPrompt].
  final RatingPrompt? prompt;

  @override
  State<RateAppCard> createState() => _RateAppCardState();
}

class _RateAppCardState extends State<RateAppCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _twinkle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  );

  RatingPrompt? get _prompt => widget.prompt ?? RatingPrompt.registered;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _twinkle.loopUnlessReduced(context, rest: 0.3);
  }

  @override
  void dispose() {
    _twinkle.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    HapticFeedback.selectionClick();
    await showRatingStory(context, prompt: _prompt);
    // The subtitle thanks you once you have been to Bazaar.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!RatingPrompt.platformSupported) return const SizedBox.shrink();
    final s = context.getString;
    final gold = AppColors.amber;
    final radius = BorderRadius.circular(16);
    final rated = _prompt?.opened ?? false;
    return Semantics(
      button: true,
      label: s.rating_settings_row,
      hint: rated ? s.rating_settings_row_done : s.rating_settings_row_desc,
      excludeSemantics: true,
      child: PressableScale(
        key: const Key('settings-rate-app'),
        onTap: _open,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: gold.withValues(alpha: 0.28)),
            gradient: LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              colors: [
                Color.alphaBlend(gold.withValues(alpha: 0.09), AppColors.card),
                AppColors.card,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: gold.withAlpha(14),
                blurRadius: 22,
                spreadRadius: -6,
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: AnimatedBuilder(
                  animation: _twinkle,
                  builder: (context, _) => CustomPaint(
                    painter: _TwinklePainter(_twinkle.value, gold),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.rating_settings_row,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    AnimatedSwitcher(
                      duration: AppMotion.card,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.leaving,
                      transitionBuilder: HandOver.transition(),
                      child: Text(
                        rated
                            ? s.rating_settings_row_done
                            : s.rating_settings_row_desc,
                        key: ValueKey(rated),
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A gold star that breathes, with two sparks orbiting it and, once a
/// loop, a quick half-turn of delight.
class _TwinklePainter extends CustomPainter {
  _TwinklePainter(this.t, this.gold);

  final double t;
  final Color gold;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final breathe = math.sin(t * math.pi * 4);
    final flip = Curves.easeInOutBack.transform(
      ((t - 0.7) / 0.18).clamp(0.0, 1.0),
    );
    canvas.drawCircle(
      c,
      19,
      Paint()..color = gold.withValues(alpha: 0.12 + 0.04 * breathe),
    );
    final r = 10.5 * (1 + 0.05 * breathe + 0.12 * math.sin(math.pi * flip));
    final spin = flip * math.pi * 2 / 5;
    final path = Path();
    for (var k = 0; k < 10; k++) {
      final a = -math.pi / 2 + spin + k * math.pi / 5;
      final len = k.isEven ? r : r * 0.48;
      final p = c + Offset(math.cos(a) * len, math.sin(a) * len);
      k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path..close(), Paint()..color = gold);
    for (var i = 0; i < 2; i++) {
      final a = t * math.pi * 2 + i * math.pi;
      final at = c + Offset(math.cos(a) * 16, math.sin(a) * 12);
      final pulse = 0.5 + 0.5 * math.sin(t * math.pi * 6 + i * 2);
      _spark(
        canvas,
        at,
        1.6 + 1.2 * pulse,
        gold.withValues(alpha: 0.5 + 0.5 * pulse),
      );
    }
  }

  void _spark(Canvas canvas, Offset at, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final len = i.isEven ? r * 1.8 : r * 0.6;
      final p = at + Offset(math.cos(a) * len, math.sin(a) * len);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TwinklePainter old) => old.t != t || old.gold != gold;
}
