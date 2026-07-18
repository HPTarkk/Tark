import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 1 — what Wakitaki is, as a console "field brief": a headline and three
/// capability lines. The VOX line keeps a live waveform glyph so the panel has
/// one moving element of its own.
class WelcomeStep extends StatelessWidget {
  final Animation<double> reveal;

  /// 0..1 slow ambient loop shared with the rest of the scene (VOX waveform).
  final Animation<double> ambient;

  const WelcomeStep({super.key, required this.reveal, required this.ambient});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return StaggeredItem(
      reveal: reveal,
      index: 0,
      count: 1,
      child: HudPanel(
        header: s.app_name,
        status: 'BRIEF',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.onboarding_welcome_title,
              style: const TextStyle(
                color: Onb.text,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s.onboarding_welcome_sub,
              style: const TextStyle(
                color: Onb.textDim,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            _Fact(icon: Icons.lan_rounded, text: s.onboarding_info_lan),
            const _FactGap(),
            _Fact(icon: Icons.cloud_off_rounded, text: s.onboarding_info_private),
            const _FactGap(),
            _Fact(
              text: s.onboarding_info_vox,
              iconBuilder: () => _MiniWaveform(ambient: ambient),
            ),
          ],
        ),
      ),
    );
  }
}

class _FactGap extends StatelessWidget {
  const _FactGap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 11);
}

class _Fact extends StatelessWidget {
  final IconData? icon;
  final Widget Function()? iconBuilder;
  final String text;

  const _Fact({this.icon, this.iconBuilder, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Amber tick + glyph, no filled chip — reads as a HUD list marker.
        SizedBox(
          width: 22,
          height: 18,
          child: Center(
            child: iconBuilder != null
                ? iconBuilder!()
                : Icon(icon, color: Onb.amber, size: 17),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: Onb.text.withAlpha(220),
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// Five slim bars dancing like a live level meter — each on its own
/// frequency so the motion never loops visibly.
class _MiniWaveform extends StatelessWidget {
  final Animation<double> ambient;

  const _MiniWaveform({required this.ambient});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ambient,
      builder: (_, _) => CustomPaint(
        size: const Size(18, 16),
        painter: _MiniWaveformPainter(t: ambient.value, color: Onb.amber),
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
