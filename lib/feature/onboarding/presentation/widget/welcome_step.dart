import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import 'onboarding_emblem.dart';

/// Beat 1 — what Wakitaki is, in one headline and three quick facts. The
/// fact chips stay alive after their entrance: each icon tile breathes on
/// its own phase of the shared [ambient] loop, and the VOX chip's icon is a
/// live waveform, not a static glyph.
class WelcomeStep extends StatelessWidget {
  final Animation<double> reveal;

  /// 0..1 slow ambient loop shared with the rest of the scene.
  final Animation<double> ambient;

  const WelcomeStep({super.key, required this.reveal, required this.ambient});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaggeredItem(
          reveal: reveal,
          index: 0,
          count: 5,
          child: Text(
            s.onboarding_welcome_title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              height: 1.3,
            ),
          ),
        ),
        const SizedBox(height: 10),
        StaggeredItem(
          reveal: reveal,
          index: 1,
          count: 5,
          child: Text(
            s.onboarding_welcome_sub,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 24),
        StaggeredItem(
          reveal: reveal,
          index: 2,
          count: 5,
          child: _FactChip(
            icon: Icons.wifi_rounded,
            text: s.onboarding_info_lan,
            ambient: ambient,
            phase: 0,
          ),
        ),
        const SizedBox(height: 10),
        StaggeredItem(
          reveal: reveal,
          index: 3,
          count: 5,
          child: _FactChip(
            icon: Icons.cloud_off_rounded,
            text: s.onboarding_info_private,
            ambient: ambient,
            phase: 2.1,
          ),
        ),
        const SizedBox(height: 10),
        StaggeredItem(
          reveal: reveal,
          index: 4,
          count: 5,
          child: _FactChip(
            text: s.onboarding_info_vox,
            ambient: ambient,
            phase: 4.2,
            // Live waveform instead of a static glyph — this chip is about
            // your voice keying the channel.
            iconBuilder: (color) =>
                _MiniWaveform(ambient: ambient, color: color),
          ),
        ),
      ],
    );
  }
}

class _FactChip extends StatelessWidget {
  final IconData? icon;
  final Widget Function(Color color)? iconBuilder;
  final String text;
  final Animation<double> ambient;
  final double phase;

  const _FactChip({
    this.icon,
    this.iconBuilder,
    required this.text,
    required this.ambient,
    required this.phase,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: ambient,
            // Each tile breathes on its own phase, so the column shimmers
            // organically instead of pulsing in lockstep.
            builder: (_, child) {
              final b = 0.5 + 0.5 * sin(2 * pi * ambient.value * 3 + phase);
              return Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.amber.withAlpha((20 + 14 * b).toInt()),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.amber.withAlpha((22 * b).toInt()),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: iconBuilder != null
                ? Center(child: iconBuilder!(AppColors.amber))
                : Icon(icon, color: AppColors.amber, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textPrimary.withAlpha(220),
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Five slim bars dancing like a live level meter — each on its own
/// frequency so the motion never loops visibly.
class _MiniWaveform extends StatelessWidget {
  final Animation<double> ambient;
  final Color color;

  const _MiniWaveform({required this.ambient, required this.color});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ambient,
      builder: (_, _) => CustomPaint(
        size: const Size(18, 16),
        painter: _MiniWaveformPainter(t: ambient.value, color: color),
      ),
    );
  }
}

class _MiniWaveformPainter extends CustomPainter {
  final double t;
  final Color color;

  const _MiniWaveformPainter({required this.t, required this.color});

  static const _freqs = [7.0, 11.0, 9.0, 13.0, 8.0];
  static const _phases = [0.0, 1.7, 3.1, 4.6, 5.9];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final gap = size.width / (_freqs.length - 1);
    final midY = size.height / 2;
    for (var i = 0; i < _freqs.length; i++) {
      final level =
          0.25 + 0.75 * (0.5 + 0.5 * sin(2 * pi * t * _freqs[i] + _phases[i]));
      final half = (size.height / 2) * level;
      final x = i * gap;
      canvas.drawLine(Offset(x, midY - half), Offset(x, midY + half), paint);
    }
  }

  @override
  bool shouldRepaint(_MiniWaveformPainter old) =>
      old.t != t || old.color != color;
}
