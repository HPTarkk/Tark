import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

enum BluetoothSignalPhase { hosting, searching, connecting }

/// A shared radio scene that changes from discovery to a two-phone handshake.
/// The moving packets represent activity, never fabricated connection progress.
class BluetoothSignalScene extends StatefulWidget {
  const BluetoothSignalScene({
    required this.phase,
    this.peers = 0,
    this.countdown,
    super.key,
  });
  final BluetoothSignalPhase phase;
  final int peers;
  final Animation<double>? countdown;
  @override
  State<BluetoothSignalScene> createState() => _BluetoothSignalSceneState();
}

class _BluetoothSignalSceneState extends State<BluetoothSignalScene>
    with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
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

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      height: 240,
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          end: widget.phase == BluetoothSignalPhase.connecting ? 1 : 0,
        ),
        duration: AppMotion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 700),
        curve: AppMotion.easeInOut,
        builder: (_, lock, _) => AnimatedBuilder(
          animation: Listenable.merge([_loop, ?widget.countdown]),
          builder: (_, _) => CustomPaint(
            painter: _RadioScene(
              _loop.value,
              lock,
              widget.phase,
              widget.peers,
              widget.countdown?.value,
              AppColors.amber,
              AppColors.green,
              AppColors.border,
              AppColors.surface,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

class _RadioScene extends CustomPainter {
  _RadioScene(
    this.time,
    this.lock,
    this.phase,
    this.peers,
    this.countdown,
    this.accent,
    this.peer,
    this.track,
    this.surface,
  );
  final double time, lock;
  final double? countdown;
  final BluetoothSignalPhase phase;
  final int peers;
  final Color accent, peer, track, surface;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width / 2 - 14, 108.0);
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final orbit = time * 2 * math.pi;
    pen
      ..color = track.withValues(alpha: 0.7)
      ..strokeWidth = 0.8;
    for (final fraction in [0.45, 0.72, 1.0]) {
      canvas.drawCircle(center, radius * fraction, pen);
    }
    for (var i = 0; i < 48; i++) {
      final angle = i * 2 * math.pi / 48;
      final bright = ((angle - orbit) % (2 * math.pi)) < 0.7;
      pen
        ..color = (bright ? accent : track).withValues(
          alpha: bright ? 0.6 : 0.55,
        )
        ..strokeWidth = i % 4 == 0 ? 1.5 : 0.8;
      final inner = radius + (i % 4 == 0 ? 4 : 7);
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center +
            Offset(
              math.cos(angle) * (radius + 11),
              math.sin(angle) * (radius + 11),
            ),
        pen,
      );
    }
    for (var wave = 0; wave < 3; wave++) {
      final t = (time + wave / 3) % 1;
      pen
        ..strokeWidth = 1.3
        ..color = accent.withValues(alpha: (1 - t) * 0.25 * (1 - lock));
      canvas.drawCircle(center, 24 + t * (radius - 24), pen);
    }
    if (phase != BluetoothSignalPhase.hosting) {
      pen
        ..strokeWidth = 1.4
        ..color = accent.withValues(alpha: 0.6 * (1 - lock));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.85),
        orbit,
        math.pi * 0.7,
        false,
        pen,
      );
      for (var i = 0; i < math.min(peers, 6); i++) {
        final bearing = -0.6 + i * 2.3;
        final pos =
            center +
            Offset(
              math.cos(bearing) * radius * 0.68,
              math.sin(bearing) * radius * 0.68,
            );
        final pulse = (math.sin(orbit + i) + 1) / 2;
        canvas.drawCircle(
          pos,
          8 + pulse * 4,
          Paint()..color = peer.withValues(alpha: 0.05 * (1 - lock)),
        );
        canvas.drawCircle(
          pos,
          3,
          Paint()
            ..color = peer.withValues(alpha: (0.45 + 0.4 * pulse) * (1 - lock)),
        );
      }
    }
    final distance = 70 - 22 * lock;
    final left = center + Offset(-distance, 10 * (1 - lock));
    final right = center + Offset(distance, -10 * (1 - lock));
    void phone(Offset p, Color color, double visibility) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: p, width: 30, height: 48),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        rect.inflate(4),
        Paint()..color = color.withValues(alpha: 0.05 * visibility),
      );
      canvas.drawRRect(
        rect,
        Paint()..color = surface.withValues(alpha: visibility),
      );
      pen
        ..strokeWidth = 1.5
        ..color = color.withValues(alpha: visibility);
      canvas.drawRRect(rect, pen);
      canvas.drawLine(p + const Offset(-5, -17), p + const Offset(5, -17), pen);
      canvas.drawCircle(
        p + const Offset(0, 16),
        1.5,
        Paint()..color = color.withValues(alpha: visibility),
      );
    }

    phone(left, accent, 0.75);
    phone(
      right,
      peer,
      phase == BluetoothSignalPhase.hosting ? 0.25 : 0.35 + 0.45 * lock,
    );
    pen
      ..strokeWidth = 1.3
      ..color = accent.withValues(alpha: 0.15 + lock * 0.3);
    final beam = Path()
      ..moveTo(left.dx + 20, left.dy)
      ..cubicTo(
        center.dx - 20,
        left.dy,
        center.dx + 20,
        right.dy,
        right.dx - 20,
        right.dy,
      );
    canvas.drawPath(beam, pen);
    final metrics = beam.computeMetrics().first;
    for (var i = 0; i < 2; i++) {
      final fraction = (time * (1 + lock) + i / 2) % 1;
      final point = metrics
          .getTangentForOffset(metrics.length * fraction)!
          .position;
      canvas.drawCircle(
        point,
        5,
        Paint()..color = accent.withValues(alpha: 0.07),
      );
      canvas.drawCircle(
        point,
        2,
        Paint()..color = accent.withValues(alpha: 0.5 + 0.3 * lock),
      );
    }
    canvas.drawCircle(center, 18, Paint()..color = surface);
    pen
      ..strokeWidth = 1.2
      ..color = accent.withValues(alpha: 0.5);
    canvas.drawCircle(center, 18, pen);
    final glyph = Path()
      ..moveTo(center.dx, center.dy - 11)
      ..lineTo(center.dx + 7, center.dy - 5)
      ..lineTo(center.dx - 6, center.dy + 6)
      ..moveTo(center.dx - 6, center.dy - 6)
      ..lineTo(center.dx + 7, center.dy + 5)
      ..lineTo(center.dx, center.dy + 11)
      ..lineTo(center.dx, center.dy - 11);
    pen
      ..strokeWidth = 1.8
      ..color = accent;
    canvas.drawPath(glyph, pen);
    if (countdown != null) {
      pen
        ..strokeWidth = 2
        ..color = accent.withValues(alpha: 0.6);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius + 16),
        -math.pi / 2,
        2 * math.pi * (1 - countdown!),
        false,
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_RadioScene old) =>
      old.time != time ||
      old.lock != lock ||
      old.peers != peers ||
      old.phase != phase ||
      old.countdown != countdown ||
      old.accent != accent ||
      old.peer != peer ||
      old.track != track ||
      old.surface != surface;
}
