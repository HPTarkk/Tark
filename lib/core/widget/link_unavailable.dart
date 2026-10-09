import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../motion/route_arrival.dart';
import '../theme/app_colors.dart';

/// A radio search settles into an unavailable link, then allows navigation.
/// The result is read on this screen, without a toast following the user home.
class LinkUnavailable extends StatefulWidget {
  const LinkUnavailable({
    required this.label,
    required this.detail,
    required this.onFinished,
    super.key,
  });
  final String label;
  final String detail;
  final VoidCallback onFinished;
  static const hold = Duration(milliseconds: 1800);

  @override
  State<LinkUnavailable> createState() => _LinkUnavailableState();
}

class _LinkUnavailableState extends State<LinkUnavailable>
    with SingleTickerProviderStateMixin, RouteArrival<LinkUnavailable> {
  late final _result = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? _hold;

  @override
  void onRouteArrived() => unawaited(_showResult());

  Future<void> _showResult() async {
    try {
      if (AppMotion.reduced(context)) {
        _result.value = 1;
      } else {
        await _result.forward().orCancel;
      }
      if (!mounted) return;
      _hold = Timer(LinkUnavailable.hold, () {
        if (mounted) widget.onFinished();
      });
    } on TickerCanceled {
      // A manual exit retires both the animation and the later navigation.
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _result.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            size: const Size(180, 136),
            painter: _UnavailablePainter(
              _result,
              AppColors.amber,
              AppColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: 16),
        AnimatedBuilder(
          animation: _result,
          child: Column(
            children: [
              Text(
                widget.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ],
          ),
          builder: (_, caption) {
            final show = ((_result.value - 0.20) / 0.45).clamp(0.0, 1.0);
            return Opacity(
              opacity: show,
              child: Transform.translate(
                offset: Offset(
                  0,
                  AppMotion.reduced(context) ? 0 : 8 * (1 - show),
                ),
                child: caption,
              ),
            );
          },
        ),
      ],
    ),
  );
}

class _UnavailablePainter extends CustomPainter {
  _UnavailablePainter(this.progress, this.accent, this.muted)
    : super(repaint: progress);
  final Animation<double> progress;
  final Color accent;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final center = size.center(Offset.zero);
    final settle = AppMotion.easeOut.transform(
      ((t - 0.25) / 0.75).clamp(0.0, 1.0),
    );
    final separation = 34 + 16 * settle;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final side in [-1.0, 1.0]) {
      final peer = center + Offset(side * separation, 0);
      pen
        ..strokeWidth = 7
        ..color = accent.withValues(alpha: 0.06 * (1 - 0.5 * settle));
      canvas.drawCircle(peer, 13, pen);
      pen
        ..strokeWidth = 1.8
        ..color = muted.withValues(alpha: 0.7 - 0.35 * settle);
      canvas.drawCircle(peer, 13, pen);
      for (var wave = 0; wave < 3; wave++) {
        final phase = ((t * 1.5 + wave * 0.25) % 1);
        pen
          ..strokeWidth = 1
          ..color = accent.withValues(alpha: 0.25 * (1 - phase) * (1 - settle));
        canvas.drawArc(
          Rect.fromCircle(center: peer, radius: 18 + phase * 18),
          side < 0 ? -pi / 3 : 2 * pi / 3,
          2 * pi / 3,
          false,
          pen,
        );
      }
    }
    pen
      ..strokeWidth = 1
      ..color = muted.withValues(alpha: 0.3 * settle);
    for (final side in [-1.0, 1.0]) {
      canvas.drawLine(
        center + Offset(side * 24, 0),
        center + Offset(side * (separation - 18), 0),
        pen,
      );
    }
    final mark = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
    pen
      ..strokeWidth = 1.5
      ..color = accent.withValues(alpha: 0.75 * mark);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: 18),
      -pi / 2,
      2 * pi * mark,
      false,
      pen,
    );
    pen.strokeWidth = 2.5;
    canvas.drawLine(
      center - Offset(6 * mark, 0),
      center + Offset(6 * mark, 0),
      pen,
    );
  }

  @override
  bool shouldRepaint(_UnavailablePainter old) =>
      old.accent != accent || old.muted != muted || old.progress != progress;
}
