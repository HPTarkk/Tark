import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';
import '../theme/theme_service.dart';
import 'theme_reveal_transition.dart';

/// Day/night scene switch for the theme setting.
///
/// The track is a miniature sky: gunmetal night with twinkling stars when
/// dark is active, warm paper daylight with drifting clouds when light is.
/// The knob is the moon/sun itself — it slides across on change, craters
/// spinning away as the sun rises — while the existing full-screen circular
/// reveal still wipes the new theme in from the tap point.
///
/// Always rendered LTR so the dark side stays on the left in both locales.
class ThemeToggle extends StatefulWidget {
  const ThemeToggle({super.key});

  @override
  State<ThemeToggle> createState() => _ThemeToggleState();
}

class _ThemeToggleState extends State<ThemeToggle>
    with SingleTickerProviderStateMixin {
  // Slow ambient loop driving star twinkle and cloud drift.
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduced) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  void _toggle(TapDownDetails details, AppThemeMode current) {
    final next = current == AppThemeMode.dark
        ? AppThemeMode.light
        : AppThemeMode.dark;
    HapticFeedback.selectionClick();
    AppRevealController.reveal(
      context: context,
      origin: details.globalPosition,
      applyChange: () => ThemeService.setMode(next),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, mode, _) {
        final target = mode == AppThemeMode.light ? 1.0 : 0.0;
        return Directionality(
          textDirection: TextDirection.ltr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => _toggle(details, mode),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: target, end: target),
              duration: reduced
                  ? Duration.zero
                  : const Duration(milliseconds: 650),
              builder: (context, t, _) {
                final sceneT = Curves.ease.transform(t);
                return Container(
                  height: 64,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    border: Border.all(color: AppColors.border),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(
                          const Color(0xFF0B0F16),
                          const Color(0xFFFFE2AE),
                          sceneT,
                        )!,
                        Color.lerp(
                          const Color(0xFF232C38),
                          const Color(0xFFFAF3E4),
                          sceneT,
                        )!,
                      ],
                    ),
                  ),
                  child: AnimatedBuilder(
                    animation: _drift,
                    child: _SceneContent(t: t, sceneT: sceneT),
                    builder: (context, content) => CustomPaint(
                      painter: _SkyPainter(sceneT: sceneT, phase: _drift.value),
                      child: content,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

// ── Labels + knob ─────────────────────────────────────────────────────────────

class _SceneContent extends StatelessWidget {
  final double t; // linear 0 (dark) → 1 (light), drives the knob slide
  final double sceneT; // eased scene morph

  const _SceneContent({required this.t, required this.sceneT});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    // Knob pops up mid-slide, like it lifts off the sky and settles back.
    final pop = 1 + 0.12 * math.sin(math.pi * t.clamp(0.0, 1.0));
    final slideT = Curves.ease.transform(t.clamp(0.0, 1.0));
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: const Alignment(0.55, 0),
          child: Opacity(
            opacity: (1 - sceneT).clamp(0.0, 1.0),
            child: Text(
              s.theme_dark,
              style: _labelStyle(const Color(0xFFDCE5EE), isFa),
            ),
          ),
        ),
        Align(
          alignment: const Alignment(-0.55, 0),
          child: Opacity(
            opacity: sceneT.clamp(0.0, 1.0),
            child: Text(
              s.theme_light,
              style: _labelStyle(const Color(0xFF6B5433), isFa),
            ),
          ),
        ),
        Align(
          alignment: Alignment(-1 + 2 * slideT, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9),
            child: Transform.scale(
              scale: pop,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(
                        const Color(0xFFF4F7FA),
                        const Color(0xFFFFE082),
                        sceneT,
                      )!,
                      Color.lerp(
                        const Color(0xFFAEBBCA),
                        const Color(0xFFF08424),
                        sceneT,
                      )!,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color.lerp(
                        const Color(0x5C8FA8C7),
                        const Color(0x80F5853F),
                        sceneT,
                      )!,
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: CustomPaint(painter: _KnobFacePainter(sceneT)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Persian is a joined script — wide letterSpacing would tear it apart, so
  // the tracking stays latin-only.
  TextStyle _labelStyle(Color color, bool isFa) => TextStyle(
    color: color,
    fontSize: isFa ? 12.5 : 11,
    fontWeight: FontWeight.w800,
    letterSpacing: isFa ? 0.4 : 3.5,
  );
}

// ── Sky: stars at night, clouds by day ───────────────────────────────────────

class _SkyPainter extends CustomPainter {
  final double sceneT; // 0 night → 1 day
  final double phase; // 0..1 ambient loop

  const _SkyPainter({required this.sceneT, required this.phase});

  // (x, y) as fractions of the track, radius in px, twinkle phase offset.
  // Kept clear of the knob's resting spot on the left.
  static const _stars = <(double, double, double, double)>[
    (0.30, 0.26, 1.5, 0.0),
    (0.38, 0.62, 1.0, 2.1),
    (0.46, 0.20, 1.2, 4.2),
    (0.52, 0.48, 0.9, 1.3),
    (0.58, 0.74, 1.1, 3.1),
    (0.64, 0.30, 1.7, 5.0),
    (0.72, 0.58, 1.0, 0.7),
    (0.78, 0.22, 1.3, 2.8),
    (0.85, 0.66, 1.1, 3.9),
    (0.90, 0.36, 1.6, 1.9),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final nightAlpha = (1 - sceneT).clamp(0.0, 1.0);
    if (nightAlpha > 0.01) {
      for (final (fx, fy, r, offset) in _stars) {
        final twinkle =
            0.45 + 0.55 * (0.5 + 0.5 * math.sin(4 * math.pi * phase + offset));
        final paint = Paint()
          ..color = const Color(
            0xFFEAF2FB,
          ).withAlpha((255 * nightAlpha * twinkle).round());
        final center = Offset(fx * size.width, fy * size.height);
        canvas.drawCircle(center, r, paint);
        if (r >= 1.5) {
          // 4-point sparkle on the bigger stars
          final reach = r * 2.6 * twinkle;
          final line = Paint()
            ..color = paint.color
            ..strokeWidth = 0.9
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(
            center - Offset(reach, 0),
            center + Offset(reach, 0),
            line,
          );
          canvas.drawLine(
            center - Offset(0, reach),
            center + Offset(0, reach),
            line,
          );
        }
      }
    }

    final dayAlpha = sceneT.clamp(0.0, 1.0);
    if (dayAlpha > 0.01) {
      _cloud(
        canvas,
        size,
        fx: 0.45,
        fy: 0.26,
        r: size.height * 0.16,
        drift: math.sin(2 * math.pi * phase) * 2.5,
        alpha: dayAlpha,
      );
      _cloud(
        canvas,
        size,
        fx: 0.62,
        fy: 0.70,
        r: size.height * 0.12,
        drift: math.cos(2 * math.pi * phase) * 3.0,
        alpha: dayAlpha * 0.85,
      );
    }
  }

  void _cloud(
    Canvas canvas,
    Size size, {
    required double fx,
    required double fy,
    required double r,
    required double drift,
    required double alpha,
  }) {
    final center = Offset(fx * size.width + drift, fy * size.height);
    // One path so the overlapping puffs fill uniformly, without seams.
    final path = Path()
      ..addOval(
        Rect.fromCircle(
          center: center.translate(-r * 1.1, r * 0.25),
          radius: r * 0.7,
        ),
      )
      ..addOval(Rect.fromCircle(center: center, radius: r))
      ..addOval(
        Rect.fromCircle(
          center: center.translate(r * 1.15, r * 0.3),
          radius: r * 0.65,
        ),
      );
    canvas.drawPath(
      path.shift(const Offset(0, 1.5)),
      Paint()..color = const Color(0xFFCE9A55).withAlpha((70 * alpha).round()),
    );
    canvas.drawPath(
      path,
      Paint()..color = Colors.white.withAlpha((235 * alpha).round()),
    );
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.sceneT != sceneT || old.phase != phase;
}

// ── Knob face: moon craters spin away as the sun rises ──────────────────────

class _KnobFacePainter extends CustomPainter {
  final double sceneT; // 0 moon → 1 sun

  const _KnobFacePainter(this.sceneT);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final moonAlpha = (1 - sceneT).clamp(0.0, 1.0);
    if (moonAlpha > 0.01) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(math.pi * sceneT);
      final crater = Paint()
        ..color = const Color(0xFF8DA0B5).withAlpha((150 * moonAlpha).round());
      canvas.drawCircle(const Offset(-6, -3), 5, crater);
      canvas.drawCircle(const Offset(6, 5), 3.5, crater);
      canvas.drawCircle(const Offset(8, -8), 2.5, crater);
      canvas.restore();
    }
    final sunAlpha = sceneT.clamp(0.0, 1.0);
    if (sunAlpha > 0.01) {
      final highlight = Paint()
        ..color = Colors.white.withAlpha((90 * sunAlpha).round())
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
      canvas.drawCircle(center.translate(-5, -5), 8, highlight);
    }
  }

  @override
  bool shouldRepaint(_KnobFacePainter old) => old.sceneT != sceneT;
}
