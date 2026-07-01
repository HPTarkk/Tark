import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';

/// Animated logo section with rotating radar arc and pulsing ring.
///
/// Owns its own [AnimationController]s so the page State only needs to drive
/// the entrance animation.
class LandingLogo extends StatefulWidget {
  const LandingLogo({super.key});

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
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
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
          animation: Listenable.merge([_pulseAnimation, _radarController]),
          child: Icon(Icons.radio, color: AppColors.amber, size: 48),
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
                child: child,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
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
    );
  }
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
