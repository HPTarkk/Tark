import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'onboarding_palette.dart';

/// Ambient wind for the onboarding journey: faint amber streaks streaming past
/// on the air, at several depths, so the whole scene reads as *moving through
/// open country* toward being on air — the sky-side companion to the horizon's
/// streaming ground.
///
/// Each streak is a short comet: brightest at the leading head, tapering to
/// nothing at the tail, undulating gently on its own slow current. Depth sets
/// everything together — near streaks are longer, faster and a touch brighter;
/// far ones are short, slow and dim. Deliberately faint so the beat content
/// stays the star.
///
/// [wave] (optional) turns each broadcast pulse (a beat change / key-up) into a
/// passing gust: the field flares brighter for the length of the pulse, then
/// settles. Drive it 0→1; values outside that range read as calm air. Owns its
/// own [Ticker] (paused by TickerMode while the route is covered) and ignores
/// pointer events. Onboarding-only — Landing keeps the peer-mesh backdrop.
class WindBackground extends StatefulWidget {
  const WindBackground({super.key, this.wave});

  /// 0..1 progress of one gust; values outside (0, 1) add nothing.
  final ValueListenable<double>? wave;

  @override
  State<WindBackground> createState() => _WindBackgroundState();
}

class _WindBackgroundState extends State<WindBackground>
    with SingleTickerProviderStateMixin {
  static const _count = 26;

  late final Ticker _ticker;
  late final List<_Streak> _streaks;
  final ValueNotifier<double> _time = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    final rng = Random();
    _streaks = List.generate(_count, (_) => _Streak.scatter(rng));
    _ticker = createTicker(
      (elapsed) => _time.value = elapsed.inMicroseconds / 1e6,
    )..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _WindPainter(
            time: _time,
            streaks: _streaks,
            color: Onb.amber,
            wave: widget.wave,
          ),
        ),
      ),
    );
  }
}

/// One wind streak: a horizontal current the head rides along, plus a slow
/// vertical sway so the air never reads as dead-straight.
class _Streak {
  final double y; // 0..1 vertical band
  final double phase; // 0..1 start offset along the flow span
  final double speed; // px/s
  final double length; // px
  final double thick; // px
  final int alpha; // base head alpha, kept faint
  final double swayAmp; // px vertical undulation
  final double swayFreq; // rad/s
  final double swayPhase;

  const _Streak({
    required this.y,
    required this.phase,
    required this.speed,
    required this.length,
    required this.thick,
    required this.alpha,
    required this.swayAmp,
    required this.swayFreq,
    required this.swayPhase,
  });

  factory _Streak.scatter(Random r) {
    // depth 0 (far) .. 1 (near) drives length/speed/weight/brightness together.
    final depth = r.nextDouble();
    return _Streak(
      y: 0.05 + r.nextDouble() * 0.9,
      phase: r.nextDouble(),
      speed: 32 + depth * 120 + r.nextDouble() * 22,
      length: 44 + depth * 132 + r.nextDouble() * 30,
      thick: 0.8 + depth * 1.5,
      alpha: (24 + depth * 44).round(),
      swayAmp: 4 + r.nextDouble() * 12,
      swayFreq: 0.18 + r.nextDouble() * 0.48,
      swayPhase: r.nextDouble() * 2 * pi,
    );
  }
}

class _WindPainter extends CustomPainter {
  final ValueListenable<double> time;
  final List<_Streak> streaks;
  final Color color;
  final ValueListenable<double>? wave;

  _WindPainter({
    required this.time,
    required this.streaks,
    required this.color,
    required this.wave,
  }) : super(repaint: wave == null ? time : Listenable.merge([time, wave]));

  /// Number of segments each comet-streak is drawn from — enough to taper and
  /// follow the sway without being wasteful.
  static const _seg = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    // Ease the whole layer in on first frames so it never pops.
    final fade = Curves.easeOut.transform((t / 1.6).clamp(0.0, 1.0));
    if (fade == 0) return;

    // A gust flares the whole field for the length of one broadcast pulse. Only
    // the brightness rides the gust — the flow itself stays a constant-speed
    // stream so nothing ever lurches.
    final waveT = wave?.value ?? 1.0;
    final gust = (waveT > 0.0 && waveT < 1.0) ? sin(pi * waveT) : 0.0;

    final paint = Paint()..strokeCap = StrokeCap.round;
    for (final s in streaks) {
      final span = size.width + s.length + 60;
      final headX = (s.phase * span + s.speed * t) % span - s.length;
      final baseY = s.y * size.height;
      final headAlpha = s.alpha * (0.6 + 0.85 * gust);

      for (var i = 0; i < _seg; i++) {
        final f0 = i / _seg; // 0 = head .. 1 = tail
        final f1 = (i + 1) / _seg;
        final xA = headX - f0 * s.length;
        final xB = headX - f1 * s.length;
        final yA = baseY + s.swayAmp * sin(s.swayFreq * t + s.swayPhase + xA * 0.012);
        final yB = baseY + s.swayAmp * sin(s.swayFreq * t + s.swayPhase + xB * 0.012);
        // Brightest at the head, tapering to transparent at the tail.
        final a = (headAlpha * (1 - f0) * fade).clamp(0.0, 255.0);
        paint
          ..color = color.withAlpha(a.toInt())
          ..strokeWidth = s.thick * (1 - 0.5 * f0);
        canvas.drawLine(Offset(xA, yA), Offset(xB, yB), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_WindPainter old) =>
      old.streaks != streaks || old.color != color || old.wave != wave;
}
