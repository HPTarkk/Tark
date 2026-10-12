import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// The [Hero] tag a Room's formation flies under between screens — so the
/// room the user is about to make on onboarding's last step is the very same
/// object that lands on the creation screen.
const roomFormationHeroTag = 'room-formation';

/// A Room being drawn around its members: blueprint, signal, then the
/// channel locking in.
///
/// Before the Room exists this is an ambient diagram — three members on a
/// triangle with signal running between them inside a blueprint frame. Once
/// it exists, [lockIn] runs the **lock-in**, a sequence told in the app's own
/// language, a radio finding its channel:
///
/// 1. *Tune* (0–360ms) — the scanning arc spins up and sweeps closed into a
///    full ring while the members are pulled together on springs, the
///    triangle tightening around the centre.
/// 2. *Lock* (360ms) — the ring closes; the frame has morphed into a round
///    emblem and punches once. The first haptic lands here.
/// 3. *Emblem* (300–760ms) — the members merge and the Room's own initial
///    springs up where they met.
/// 4. *Broadcast* (380–1300ms) — radio waves leave both sides of the emblem
///    in three staggered pulses while the confirmation badge pops onto its
///    rim and draws its check (the second, lighter haptic).
///
/// One controller drives all of it, owned by the page so the page can skip
/// it with a tap; every beat is an interval of that one value, painted by a
/// single [CustomPainter] — no per-beat tickers, no layout per frame.
class RoomFormation extends StatefulWidget {
  const RoomFormation({
    this.assembling = false,
    this.lockIn,
    this.emblem = '',
    super.key,
  });

  /// Creation is in flight: the signal runs faster.
  final bool assembling;

  /// 0 → 1 across [lockInDuration] once the Room exists; null before.
  final Animation<double>? lockIn;

  /// The Room's name; its first glyph becomes the emblem.
  final String emblem;

  /// The whole lock-in. The page hands over to the next screen when it ends.
  static const Duration lockInDuration = Duration(milliseconds: 1300);

  /// Where the ring closes — the primary haptic beat.
  static const double lockBeat = 360 / 1300;

  /// Where the confirmation check lands — the secondary haptic beat.
  static const double checkBeat = 640 / 1300;

  @override
  State<RoomFormation> createState() => _RoomFormationState();
}

/// The fraction of [RoomFormation.lockInDuration] between [fromMs] and [toMs]
/// that [value] has covered, clamped to 0…1.
double _span(double value, int fromMs, int toMs) {
  final ms = value * RoomFormation.lockInDuration.inMilliseconds;
  return ((ms - fromMs) / (toMs - fromMs)).clamp(0.0, 1.0);
}

/// A damped spring as a curve: overshoots and settles like something with
/// mass, which is what makes the emblem read as *landing* rather than
/// scaling.
class _Spring extends Curve {
  const _Spring({this.damping = 0.45, this.frequency = 2.2});

  final double damping;
  final double frequency;

  @override
  double transformInternal(double t) {
    final omega = 2 * math.pi * frequency;
    final damped = omega * math.sqrt(1 - damping * damping);
    return 1 - math.exp(-damping * omega * t) * math.cos(damped * t);
  }
}

const _pop = _Spring();
const _settle = _Spring(damping: 0.72, frequency: 1.6);

class _RoomFormationState extends State<RoomFormation>
    with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  String get _initial {
    final trimmed = widget.emblem.trim();
    // Runes, not code units: a Persian name's first glyph is not
    // necessarily one UTF-16 unit.
    return trimmed.isEmpty
        ? ''
        : String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final lockIn = widget.lockIn ?? const AlwaysStoppedAnimation<double>(0);
    final initial = _initial;
    return RepaintBoundary(
      child: SizedBox(
        height: 200,
        child: AnimatedBuilder(
          animation: Listenable.merge([_loop, lockIn]),
          builder: (_, _) {
            final s = lockIn.value;
            final color = Color.lerp(
              AppColors.amber,
              AppColors.green,
              Curves.easeOut.transform(_span(s, 360, 720)),
            )!;
            final mark = _pop.transform(_span(s, 300, 900));
            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RoomPainter(
                      time: _loop.value,
                      lockIn: s,
                      assembling: widget.assembling,
                      accent: AppColors.amber,
                      green: AppColors.green,
                      border: AppColors.border,
                      onGreen: AppColors.background,
                    ),
                  ),
                ),
                if (initial.isNotEmpty && s > 0)
                  Opacity(
                    opacity: _span(s, 300, 440),
                    child: Transform.scale(
                      scale: lerpDouble(0.35, 1, mark),
                      child: Text(
                        initial,
                        key: const Key('room-formation-emblem'),
                        style: TextStyle(
                          color: color,
                          fontSize: 40,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RoomPainter extends CustomPainter {
  _RoomPainter({
    required this.time,
    required this.lockIn,
    required this.assembling,
    required this.accent,
    required this.green,
    required this.border,
    required this.onGreen,
  });
  final double time, lockIn;
  final bool assembling;
  final Color accent, green, border, onGreen;

  static const _nodes = [Offset(0, -28), Offset(-30, 22), Offset(30, 22)];

  @override
  void paint(Canvas canvas, Size size) {
    final s = lockIn;
    final center = size.center(Offset.zero);
    final success = Curves.easeOut.transform(_span(s, 360, 720));
    final color = Color.lerp(accent, green, success)!;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // ── Blueprint: the outer frame and its corner ticks fade and drift
    // outward as the emblem takes over.
    final blueprint = 1 - Curves.easeOut.transform(_span(s, 0, 320));
    if (blueprint > 0) {
      final drift = 14 * (1 - blueprint);
      pen
        ..strokeWidth = 1
        ..color = border.withValues(alpha: border.a * blueprint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: center, width: 154, height: 140),
          const Radius.circular(44),
        ).inflate(drift),
        pen,
      );
      for (var i = 0; i < 4; i++) {
        final a = i * math.pi / 2 + math.pi / 4;
        final dir = Offset(math.cos(a), math.sin(a));
        final start = center + Offset(dir.dx * 94, dir.dy * 80) + dir * drift;
        canvas.drawLine(start, start + dir * 10, pen);
      }
    }

    // ── Frame → emblem: the rounded rectangle morphs into a circle on a
    // spring, and punches once when the ring locks.
    final morph = _settle.transform(_span(s, 100, 560));
    final punch = s <= 0
        ? 0.0
        : math.sin(math.pi * _span(s, 360, 560)) *
              (1 - _span(s, 360, 560)) *
              0.09;
    final w = lerpDouble(126, 104, morph)! * (1 + punch);
    final h = lerpDouble(112, 104, morph)! * (1 + punch);
    final r = lerpDouble(30, 52, morph)! * (1 + punch);
    final frame = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: w, height: h),
      Radius.circular(r),
    );
    if (success > 0) {
      canvas.drawRRect(
        frame,
        Paint()..color = color.withValues(alpha: 0.10 * success),
      );
    }
    pen
      ..strokeWidth = 7
      ..color = color.withValues(alpha: 0.07 + 0.08 * success);
    canvas.drawRRect(frame, pen);
    pen
      ..strokeWidth = 1.8 + 0.6 * success
      ..color = color.withValues(alpha: 0.65 + 0.35 * success);
    canvas.drawRRect(frame, pen);

    // ── Members: pulled together on springs, one after another, until
    // they meet in the middle and become the emblem.
    final gather = <double>[
      for (var i = 0; i < _nodes.length; i++)
        _settle.transform(_span(s, i * 40, 320 + i * 40)),
    ];
    final memberAlpha = 1 - _span(s, 300, 420);
    if (memberAlpha > 0) {
      final points = [
        for (var i = 0; i < _nodes.length; i++)
          center + _nodes[i] * (1 - gather[i]),
      ];
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final q = points[(i + 1) % points.length];
        pen
          ..strokeWidth = 1
          ..color = color.withValues(alpha: 0.2 * memberAlpha);
        canvas.drawLine(p, q, pen);
        final speed = assembling || s > 0 ? 2 : 1;
        final phase = (time * speed + i / 3) % 1;
        canvas.drawCircle(
          Offset.lerp(p, q, phase)!,
          2.2,
          Paint()..color = color.withValues(alpha: 0.7 * memberAlpha),
        );
        canvas.drawCircle(
          p,
          12,
          Paint()..color = color.withValues(alpha: 0.09 * memberAlpha),
        );
        pen
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: memberAlpha);
        canvas.drawCircle(p, 7, pen);
        canvas.drawCircle(
          p,
          2,
          Paint()..color = color.withValues(alpha: memberAlpha),
        );
      }
    }

    // ── The scanning arc: spins up and sweeps closed into a full ring —
    // the channel locking in.
    final tune = AppMotion.easeInOut.transform(_span(s, 0, 360));
    final ringMorph = Curves.easeOut.transform(_span(s, 0, 360));
    final ringRect = Rect.fromCenter(
      center: center,
      width: lerpDouble(186, 150, ringMorph)!,
      height: lerpDouble(174, 150, ringMorph)!,
    );
    final sweep = lerpDouble(math.pi / 3, 2 * math.pi, tune)!;
    final spin = time * 2 * math.pi + tune * 2.5 * math.pi;
    final flash = s <= 0 ? 0.0 : 1 - _span(s, 360, 700);
    final locked = s >= RoomFormation.lockBeat;
    pen
      ..strokeWidth = 1.2 + (locked ? 1.6 * flash : 0)
      ..color = color.withValues(
        alpha: (0.35 + 0.25 * tune + (locked ? 0.4 * flash : 0)).clamp(0, 1),
      );
    if (locked) {
      canvas.drawOval(ringRect, pen);
    } else {
      canvas.drawArc(ringRect, spin, sweep, false, pen);
    }

    // The lock itself: one bright burst off the ring.
    if (locked && flash > 0) {
      final burst = Curves.easeOut.transform(_span(s, 360, 700));
      pen
        ..strokeWidth = 3 * (1 - burst) + 0.5
        ..color = color.withValues(alpha: 0.7 * (1 - burst));
      canvas.drawCircle(center, 75 + 26 * burst, pen);
    }

    // ── Broadcast: three pulses of radio waves off both sides of the
    // emblem, like the mark on a transmit button.
    for (var j = 0; j < 3; j++) {
      final from = 380 + j * 150;
      final p = _span(s, from, from + 620);
      if (p <= 0 || p >= 1) continue;
      final eased = Curves.easeOut.transform(p);
      final radius = 62 + 78 * eased;
      pen
        ..strokeWidth = 2.6 * (1 - eased) + 0.8
        ..color = color.withValues(alpha: 0.6 * (1 - p));
      final rect = Rect.fromCircle(center: center, radius: radius);
      const half = math.pi / 5;
      canvas.drawArc(rect, -half, 2 * half, false, pen);
      canvas.drawArc(rect, math.pi - half, 2 * half, false, pen);
    }

    // ── The confirmation badge pops onto the emblem's rim, then draws
    // its check.
    final badge = _pop.transform(_span(s, 560, 900));
    if (badge > 0) {
      final rim = 52 * (1 + punch) * math.sqrt1_2;
      final origin = center + Offset(rim, -rim);
      canvas.drawCircle(
        origin,
        14 * badge,
        Paint()..color = green.withValues(alpha: _span(s, 560, 640)),
      );
      final draw = Curves.easeOut.transform(_span(s, 640, 860));
      if (draw > 0) {
        final check = Path()
          ..moveTo(origin.dx - 5, origin.dy)
          ..lineTo(origin.dx - 1, origin.dy + 4)
          ..lineTo(origin.dx + 6, origin.dy - 4);
        final metric = check.computeMetrics().first;
        pen
          ..strokeWidth = 2
          ..color = onGreen;
        canvas.drawPath(metric.extractPath(0, metric.length * draw), pen);
      }
    }
  }

  @override
  bool shouldRepaint(_RoomPainter old) =>
      old.time != time ||
      old.lockIn != lockIn ||
      old.assembling != assembling ||
      old.accent != accent ||
      old.green != green ||
      old.border != border ||
      old.onGreen != onGreen;
}
