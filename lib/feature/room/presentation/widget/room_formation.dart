import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// A Room being drawn around its members: blueprint, signal, then ready.
class RoomFormation extends StatefulWidget {
  const RoomFormation({this.assembling = false, this.ready = false, super.key});
  final bool assembling;
  final bool ready;
  @override
  State<RoomFormation> createState() => _RoomFormationState();
}

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

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      height: 200,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.ready ? 1 : 0),
        duration: AppMotion.reduced(context)
            ? Duration.zero
            : const Duration(milliseconds: 650),
        curve: AppMotion.easeOut,
        builder: (_, ready, _) => AnimatedBuilder(
          animation: _loop,
          builder: (_, _) => CustomPaint(
            painter: _RoomPainter(
              _loop.value,
              ready,
              widget.assembling,
              AppColors.amber,
              AppColors.green,
              AppColors.border,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
}

class _RoomPainter extends CustomPainter {
  _RoomPainter(
    this.time,
    this.ready,
    this.assembling,
    this.accent,
    this.green,
    this.border,
  );
  final double time, ready;
  final bool assembling;
  final Color accent, green, border;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final color = Color.lerp(accent, green, ready)!;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final frame = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 126, height: 112),
      const Radius.circular(30),
    );
    pen
      ..strokeWidth = 1
      ..color = border;
    canvas.drawRRect(frame.inflate(14), pen);
    for (var i = 0; i < 4; i++) {
      final a = i * math.pi / 2 + math.pi / 4;
      final start = center + Offset(math.cos(a) * 94, math.sin(a) * 80);
      canvas.drawLine(
        start,
        start + Offset(math.cos(a) * 10, math.sin(a) * 10),
        pen,
      );
    }
    pen
      ..strokeWidth = 7
      ..color = color.withValues(alpha: 0.07);
    canvas.drawRRect(frame, pen);
    pen
      ..strokeWidth = 1.8
      ..color = color.withValues(alpha: 0.65);
    canvas.drawRRect(frame, pen);
    final nodes = [
      center + const Offset(0, -28),
      center + const Offset(-30, 22),
      center + const Offset(30, 22),
    ];
    for (var i = 0; i < nodes.length; i++) {
      final p = nodes[i];
      final q = nodes[(i + 1) % nodes.length];
      pen
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.2 + 0.35 * ready);
      canvas.drawLine(p, q, pen);
      final phase = (time * (assembling ? 2 : 1) + i / 3) % 1;
      final signal = Offset.lerp(p, q, phase)!;
      canvas.drawCircle(
        signal,
        2.2,
        Paint()..color = color.withValues(alpha: 0.7),
      );
      canvas.drawCircle(p, 12, Paint()..color = color.withValues(alpha: 0.09));
      pen
        ..strokeWidth = 1.6
        ..color = color;
      canvas.drawCircle(p, 7, pen);
      canvas.drawCircle(p, 2, Paint()..color = color);
    }
    final orbit = time * 2 * math.pi;
    pen
      ..strokeWidth = 1.2
      ..color = color.withValues(alpha: 0.35);
    canvas.drawArc(
      Rect.fromCenter(center: center, width: 186, height: 174),
      orbit,
      math.pi / 3,
      false,
      pen,
    );
    if (ready > 0) {
      final origin = center + const Offset(52, -42);
      canvas.drawCircle(
        origin,
        14,
        Paint()..color = green.withValues(alpha: ready),
      );
      pen
        ..strokeWidth = 2
        ..color = const Color(0xff10251c).withValues(alpha: ready);
      final path = Path()
        ..moveTo(origin.dx - 5, origin.dy)
        ..lineTo(origin.dx - 1, origin.dy + 4)
        ..lineTo(origin.dx + 6, origin.dy - 4);
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(_RoomPainter old) =>
      old.time != time ||
      old.ready != ready ||
      old.assembling != assembling ||
      old.accent != accent ||
      old.green != green ||
      old.border != border;
}
