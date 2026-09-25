import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';

/// The cold-start "finding your partner again" animation.
///
/// Three things move, each saying one fact:
/// - ripples leave the Bluetooth core — this phone is calling out;
/// - two small radios orbit it in opposite directions and brighten as they
///   pass each other — the two phones looking for one another;
/// - the outer ring drains over [countdown] — how long is left before the app
///   gives up and hands back the home screen.
///
/// One painter on one looping controller (plus the countdown the caller owns),
/// for the same reason as [LinkEstablished]: it has to hold 60 fps on the
/// app's floor device, so glows are layered strokes rather than blurs.
class BluetoothResumeBeacon extends StatefulWidget {
  const BluetoothResumeBeacon({super.key, required this.countdown});

  /// 0 → 1 as the attempt's time runs out.
  final Animation<double> countdown;

  @override
  State<BluetoothResumeBeacon> createState() => _BluetoothResumeBeaconState();
}

class _BluetoothResumeBeaconState extends State<BluetoothResumeBeacon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  )..repeat();

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read through the theme listenable so a theme flip mid-attempt repaints
    // with the new palette rather than the one captured at construction.
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, _, _) => SizedBox.square(
        dimension: 240,
        child: Stack(
          alignment: Alignment.center,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: const Size.square(240),
                painter: _BeaconPainter(
                  loop: _loop,
                  countdown: widget.countdown,
                  accent: AppColors.amber,
                  track: AppColors.border,
                ),
              ),
            ),
            _Core(loop: _loop),
          ],
        ),
      ),
    );
  }
}

/// The breathing Bluetooth mark at the centre.
class _Core extends StatelessWidget {
  const _Core({required this.loop});

  final Animation<double> loop;

  @override
  Widget build(BuildContext context) {
    final core = Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.card,
        border: Border.all(color: AppColors.amber.withAlpha(150), width: 2),
      ),
      child: Icon(
        Icons.bluetooth_searching_rounded,
        color: AppColors.amber,
        size: 34,
      ),
    );
    return AnimatedBuilder(
      animation: loop,
      builder: (context, child) {
        // Two breaths per loop, in step with the ripples leaving it.
        final breath = 0.5 - 0.5 * math.cos(loop.value * 4 * math.pi);
        return Transform.scale(scale: 1 + 0.06 * breath, child: child);
      },
      child: core,
    );
  }
}

class _BeaconPainter extends CustomPainter {
  _BeaconPainter({
    required this.loop,
    required this.countdown,
    required this.accent,
    required this.track,
  }) : super(repaint: Listenable.merge([loop, countdown]));

  final Animation<double> loop;
  final Animation<double> countdown;
  final Color accent;
  final Color track;

  static const _coreRadius = 36.0;
  static const _ripples = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2 - 6;
    final t = loop.value;

    _paintRipples(canvas, center, outer - 14, t);
    _paintOrbiters(canvas, center, outer - 34, t);
    _paintCountdown(canvas, center, outer);
  }

  void _paintRipples(Canvas canvas, Offset center, double maxR, double t) {
    final paint = Paint()..style = PaintingStyle.stroke;
    for (var i = 0; i < _ripples; i++) {
      final p = (t + i / _ripples) % 1.0;
      final eased = Curves.easeOutCubic.transform(p);
      final r = _coreRadius + (maxR - _coreRadius) * eased;
      final fade = (1 - p) * (1 - p);
      paint
        ..strokeWidth = 2.5 * (1 - p) + 0.5
        ..color = accent.withValues(alpha: 0.55 * fade);
      canvas.drawCircle(center, r, paint);
    }
  }

  void _paintOrbiters(Canvas canvas, Offset center, double r, double t) {
    // A faint orbit so the two radios read as travelling a path.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = track.withValues(alpha: 0.6),
    );

    final a = t * 2 * math.pi - math.pi / 2;
    final b = -t * 2 * math.pi + math.pi / 2;
    // Closest approach (angles meet) twice per loop — brighten there, as if
    // the two phones glimpse each other in passing.
    final gap = ((a - b) % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    final near = 1 - (math.min(gap, 2 * math.pi - gap) / math.pi);
    final glow = math.pow(near, 3).toDouble();

    for (final (angle, dir) in [(a, 1.0), (b, -1.0)]) {
      // Comet tail: a few dots stepping back along the orbit.
      for (var k = 5; k >= 1; k--) {
        final ta = angle - dir * k * 0.09;
        canvas.drawCircle(
          center + Offset(math.cos(ta), math.sin(ta)) * r,
          3.6 - k * 0.45,
          Paint()..color = accent.withValues(alpha: 0.32 * (1 - k / 6)),
        );
      }
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * r;
      canvas.drawCircle(
        pos,
        9 + 5 * glow,
        Paint()..color = accent.withValues(alpha: 0.12 + 0.18 * glow),
      );
      canvas.drawCircle(pos, 5, Paint()..color = accent);
    }
  }

  void _paintCountdown(Canvas canvas, Offset center, double r) {
    final rect = Rect.fromCircle(center: center, radius: r);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = track.withValues(alpha: 0.7),
    );
    final left = 1 - countdown.value.clamp(0.0, 1.0);
    if (left <= 0) return;
    final sweep = 2 * math.pi * left;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Soft halo under the arc, then the arc itself.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      arc
        ..strokeWidth = 9
        ..color = accent.withValues(alpha: 0.14),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      arc
        ..strokeWidth = 3
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_BeaconPainter old) =>
      old.accent != accent || old.track != track;
}
