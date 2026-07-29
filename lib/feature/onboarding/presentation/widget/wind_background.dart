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
/// passing gust: the field flares brighter *and surges forward* for the length
/// of the pulse, then settles back to its steady stream — the sky-wide echo of
/// the beat panel being thrown across the stage. Drive it 0→1; values outside
/// that range read as calm air. Owns its own [Ticker] (paused by TickerMode
/// while the route is covered) and ignores pointer events. Onboarding-only —
/// Landing keeps the peer-mesh backdrop.
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

  /// Peak extra px/s a gust adds to a mid-depth streak.
  static const _gustSpeed = 620.0;

  late final Ticker _ticker;
  late final List<_Streak> _streaks;
  final ValueNotifier<double> _time = ValueNotifier(0);

  /// Distance the gusts have carried the field, *integrated* rather than added
  /// to the velocity term. Adding a speed to `speed * t` would rewrite where
  /// every streak has been since t=0 and make the whole field jump; carrying
  /// the integral means position is always continuous, so a gust accelerates
  /// the air and hands it back without a seam. Never resets — positions are
  /// taken modulo the flow span, so it can grow forever.
  final ValueNotifier<double> _gust = ValueNotifier(0);
  double _lastT = 0;

  @override
  void initState() {
    super.initState();
    final rng = Random();
    _streaks = List.generate(_count, (_) => _Streak.scatter(rng));
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    // Clamped so a dropped frame or a resumed ticker cannot teleport the field.
    final dt = (t - _lastT).clamp(0.0, 1 / 20);
    _lastT = t;

    final w = widget.wave?.value ?? 1.0;
    if (w > 0.0 && w < 1.0) {
      _gust.value += _gustSpeed * sin(pi * w) * dt;
    }
    _time.value = t;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    _gust.dispose();
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
            gust: _gust,
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

  /// How much of a gust this streak picks up, by depth: near streaks get
  /// carried (and stretched) far more than distant ones. This is what turns the
  /// surge into parallax instead of a flat pan.
  final double drag;

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
    required this.drag,
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
      drag: 0.28 + depth * 1.05,
    );
  }
}

class _WindPainter extends CustomPainter {
  final ValueListenable<double> time;

  /// Accumulated gust distance; see [_WindBackgroundState._gust].
  final ValueListenable<double> gust;
  final List<_Streak> streaks;
  final Color color;
  final ValueListenable<double>? wave;

  _WindPainter({
    required this.time,
    required this.gust,
    required this.streaks,
    required this.color,
    required this.wave,
  }) : super(
         repaint: wave == null
             ? Listenable.merge([time, gust])
             : Listenable.merge([time, gust, wave]),
       );

  /// Number of segments each comet-streak is drawn from — enough to taper and
  /// follow the sway without being wasteful.
  static const _seg = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    // Ease the whole layer in on first frames so it never pops.
    final fade = Curves.easeOut.transform((t / 1.6).clamp(0.0, 1.0));
    if (fade == 0) return;

    // A gust flares the field and, via the integrated [gust] distance, drives
    // it forward for the length of one broadcast pulse. Near streaks are
    // carried further than far ones, so the surge reads as parallax depth
    // rushing past rather than the whole sky sliding as one sheet.
    final waveT = wave?.value ?? 1.0;
    final flare = (waveT > 0.0 && waveT < 1.0) ? sin(pi * waveT) : 0.0;
    final carried = gust.value;

    final paint = Paint()..strokeCap = StrokeCap.round;
    for (final s in streaks) {
      final span = size.width + s.length + 60;
      final headX =
          (s.phase * span + s.speed * t + carried * s.drag) % span - s.length;
      final baseY = s.y * size.height;
      final headAlpha = s.alpha * (0.6 + 0.85 * flare);
      // Streaks stretch while the air is moving — drawn length only, so the
      // head keeps its steady position and nothing snaps when the gust ends.
      final len = s.length * (1 + 1.1 * flare * s.drag);

      for (var i = 0; i < _seg; i++) {
        final f0 = i / _seg; // 0 = head .. 1 = tail
        final f1 = (i + 1) / _seg;
        final xA = headX - f0 * len;
        final xB = headX - f1 * len;
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
      old.streaks != streaks ||
      old.color != color ||
      old.wave != wave ||
      old.gust != gust;
}
