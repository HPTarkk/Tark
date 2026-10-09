import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/tark_mark.dart';

/// Animated logo section with rotating radar arc and pulsing ring.
///
/// Owns its own [AnimationController]s so the page State only needs to drive
/// the entrance animation.
class LandingLogo extends StatefulWidget {
  const LandingLogo({this.reveal, super.key});
  final Animation<double>? reveal;

  @override
  State<LandingLogo> createState() => _LandingLogoState();
}

class _LandingLogoState extends State<LandingLogo>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _radarController;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pulseController.loopUnlessReduced(context, reverse: true);
    _radarController.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _radarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      children: [
        AnimatedBuilder(
          animation: Listenable.merge([
            _pulseAnimation,
            _radarController,
            ?widget.reveal,
          ]),
          child: TarkMark(
            size: 48,
            color: AppColors.amber,
            colorDim: AppColors.amberDim,
          ),
          builder: (_, child) => Stack(
            alignment: Alignment.center,
            children: [
              // Rotating radar arc
              Transform.rotate(
                angle: _radarController.value * 2 * pi,
                child: CustomPaint(
                  size: const Size(130, 130),
                  painter: _RadarPainter(
                    sweep: _pulseAnimation.value,
                    color: AppColors.amber,
                  ),
                ),
              ),
              if (widget.reveal != null)
                RepaintBoundary(
                  child: CustomPaint(
                    size: const Size(144, 144),
                    painter: _LogoIgnitionPainter(
                      widget.reveal!.value,
                      AppColors.amber,
                    ),
                  ),
                ),
              // Outer pulsing ring
              Container(
                width: 110 + 6 * _pulseAnimation.value,
                height: 110 + 6 * _pulseAnimation.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppColors.amber.withAlpha(
                      (30 + 50 * _pulseAnimation.value).toInt(),
                    ),
                    width: 1,
                  ),
                ),
              ),
              // Core icon circle
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.card,
                  border: Border.all(
                    color: AppColors.amber.withAlpha(
                      (80 + 80 * _pulseAnimation.value).toInt(),
                    ),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.amber.withAlpha(
                        (30 + 70 * _pulseAnimation.value).toInt(),
                      ),
                      blurRadius: 28 + 14 * _pulseAnimation.value,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Opacity(
                  opacity: widget.reveal?.value ?? 1,
                  child: Transform.scale(
                    scale: 0.82 + 0.18 * (widget.reveal?.value ?? 1),
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        AnimatedBuilder(
          animation: widget.reveal ?? const AlwaysStoppedAnimation(1.0),
          builder: (_, wordmark) {
            final reveal =
                ((widget.reveal?.value ?? 1) - 0.35).clamp(0.0, 0.65) / 0.65;
            return Opacity(
              opacity: reveal,
              child: Transform.translate(
                offset: Offset(0, 12 * (1 - reveal)),
                child: wordmark,
              ),
            );
          },
          child: Column(
            children: [
              Text(
                s.app_name,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 30,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 6),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  s.app_subtitle,
                  style: TextStyle(
                    color: AppColors.textSecondary.withAlpha(160),
                    fontSize: 11,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A single transmission draws the rim, lights its ticks, and releases a halo.
/// Stroke glows avoid per-frame blur filters on the S8.
class _LogoIgnitionPainter extends CustomPainter {
  const _LogoIgnitionPainter(this.progress, this.accent);
  final double progress;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.43;
    final draw = (progress / 0.65).clamp(0.0, 1.0);
    final fade = 1 - ((progress - 0.65) / 0.35).clamp(0.0, 1.0);
    final arc = Rect.fromCircle(center: center, radius: radius);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final (width, alpha) in [(7.0, 0.10), (2.0, 0.85)]) {
      pen
        ..strokeWidth = width
        ..color = accent.withValues(alpha: alpha * fade);
      canvas.drawArc(arc, -pi / 2, 2 * pi * draw, false, pen);
    }
    for (var i = 0; i < 12; i++) {
      if (draw < i / 12) continue;
      final angle = -pi / 2 + i * pi / 6;
      final direction = Offset(cos(angle), sin(angle));
      pen
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: 0.45 * fade);
      canvas.drawLine(
        center + direction * (radius + 6),
        center + direction * (radius + 9),
        pen,
      );
    }
    final burst = ((progress - 0.45) / 0.55).clamp(0.0, 1.0);
    pen
      ..strokeWidth = 1
      ..color = accent.withValues(alpha: 0.3 * (1 - burst) * draw);
    canvas.drawCircle(center, radius + 12 * burst, pen);
  }

  @override
  bool shouldRepaint(_LogoIgnitionPainter old) =>
      old.progress != progress || old.accent != accent;
}

// ── Radar sweep painter ───────────────────────────────────────────────────────

class _RadarPainter extends CustomPainter {
  final double sweep;
  final Color color;

  const _RadarPainter({required this.sweep, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [
          color.withAlpha(0),
          color.withAlpha((60 * sweep).toInt()),
          color.withAlpha(0),
        ],
        stops: const [0.0, 0.25, 0.5],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.sweep != sweep || old.color != color;
}
