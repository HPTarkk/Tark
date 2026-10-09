import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../domain/entity/transfer_mode.dart';

/// A shared router joins two phones; a hotspot broadcasts from one phone.
/// One lightweight painter draws those distinct topologies and their arrival.
class NetworkLinkEstablished extends StatefulWidget {
  const NetworkLinkEstablished({
    required this.hotspot,
    this.roomName,
    this.onComplete,
    super.key,
  });

  final bool hotspot;
  final String? roomName;
  final VoidCallback? onComplete;
  static const sequence = Duration(milliseconds: 1000);
  static const hold = Duration(milliseconds: 1200);

  @override
  State<NetworkLinkEstablished> createState() => _NetworkLinkEstablishedState();
}

class _NetworkLinkEstablishedState extends State<NetworkLinkEstablished>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(
    vsync: this,
    duration: NetworkLinkEstablished.sequence,
  );
  Timer? _finish;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // Start after the first paint, so the full beat survives a route arrival.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppMotion.reduced(context)) {
        _progress.value = 1;
        _finish = Timer(const Duration(milliseconds: 450), _complete);
      } else {
        _progress.forward().then((_) {
          if (mounted) {
            _finish = Timer(const Duration(milliseconds: 200), _complete);
          }
        });
      }
    });
  }

  void _complete() => widget.onComplete?.call();
  @override
  void dispose() {
    _finish?.cancel();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, _, _) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.hotspot ? s.transport_hotspot : s.transport_wifi,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                RepaintBoundary(
                  child: CustomPaint(
                    key: ValueKey(
                      widget.hotspot
                          ? 'hotspot-link-topology'
                          : 'wifi-link-topology',
                    ),
                    size: const Size(232, 190),
                    painter: _NetworkPainter(
                      progress: _progress,
                      hotspot: widget.hotspot,
                      accent: AppColors.green,
                      pending: AppColors.amber,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                AnimatedBuilder(
                  animation: _progress,
                  builder: (_, child) {
                    final t = AppMotion.easeOut.transform(
                      _span(_progress.value, .28, .72),
                    );
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          AppMotion.reduced(context) ? 0 : 12 * (1 - t),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.hotspot
                              ? s.network_link_hotspot_title
                              : s.network_link_wifi_title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 21,
                            fontWeight: FontWeight.w800,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.hotspot
                              ? s.network_link_hotspot_detail
                              : s.network_link_wifi_detail,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.7,
                          ),
                        ),
                        if (widget.roomName case final name?) ...[
                          const SizedBox(height: 18),
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.green,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the verified network's acknowledgement over the live page once.
/// The live subtree keeps its state/socket throughout the beat and reveal.
class NetworkConnectionArrival extends StatefulWidget {
  const NetworkConnectionArrival({
    required this.mode,
    required this.child,
    this.roomName,
    super.key,
  });
  final TransferMode mode;
  final String? roomName;
  final Widget child;
  @override
  State<NetworkConnectionArrival> createState() =>
      _NetworkConnectionArrivalState();
}

class _NetworkConnectionArrivalState extends State<NetworkConnectionArrival> {
  bool _arrived = false;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeSemantics(
        excluding: !_arrived,
        child: IgnorePointer(ignoring: !_arrived, child: widget.child),
      ),
      if (!_arrived)
        Scaffold(
          key: const ValueKey('network-connection-success'),
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: NetworkLinkEstablished(
              hotspot: widget.mode == TransferMode.hotspot,
              roomName: widget.roomName,
              onComplete: () {
                if (mounted) setState(() => _arrived = true);
              },
            ),
          ),
        ),
    ],
  );
}

double _span(double value, double start, double end) =>
    ((value - start) / (end - start)).clamp(0, 1);

class _NetworkPainter extends CustomPainter {
  _NetworkPainter({
    required this.progress,
    required this.hotspot,
    required this.accent,
    required this.pending,
  }) : super(repaint: progress);
  final Animation<double> progress;
  final bool hotspot;
  final Color accent, pending;

  Paint _stroke(Color color, [double width = 2]) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 232, size.height / 190);
    final t = progress.value;
    final settle = _span(t, .54, .82);
    final color = Color.lerp(pending, accent, settle)!;
    if (hotspot) {
      const host = Offset(70, 90), peer = Offset(194, 90);
      _link(
        canvas,
        host + const Offset(20, 0),
        peer - const Offset(14, 0),
        t,
        color,
      );
      for (var i = 0; i < 3; i++) {
        final lit = _span(t, .08 + i * .08, .30 + i * .08);
        canvas.drawArc(
          Rect.fromCircle(center: host, radius: 40 + i * 14),
          -.6,
          1.2,
          false,
          _stroke(color.withValues(alpha: lit * .40), 1.5),
        );
      }
      _phone(canvas, host, color, width: 34, height: 58);
      _phone(canvas, peer, color);
      _check(canvas, const Offset(132, 151), t);
    } else {
      const hub = Offset(116, 43),
          left = Offset(42, 139),
          right = Offset(190, 139);
      _link(
        canvas,
        hub + const Offset(-12, 16),
        left - const Offset(0, 24),
        t,
        color,
      );
      _link(
        canvas,
        hub + const Offset(12, 16),
        right - const Offset(0, 24),
        t,
        color,
      );
      canvas.drawCircle(hub, 25, Paint()..color = color.withValues(alpha: .08));
      canvas.drawCircle(hub, 25, _stroke(color.withValues(alpha: .65), 1.5));
      for (var i = 0; i < 2; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: hub + const Offset(0, 7), radius: 8 + i * 6),
          math.pi * 1.25,
          math.pi * .5,
          false,
          _stroke(color),
        );
      }
      canvas.drawCircle(hub + const Offset(0, 7), 2, Paint()..color = color);
      _phone(canvas, left, color);
      _phone(canvas, right, color);
      _check(canvas, const Offset(116, 140), t);
    }
    canvas.restore();
  }

  void _phone(
    Canvas canvas,
    Offset center,
    Color color, {
    double width = 25,
    double height = 44,
  }) {
    final rect = Rect.fromCenter(center: center, width: width, height: height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      Paint()..color = color.withValues(alpha: .09),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(5)),
      _stroke(color),
    );
    canvas.drawLine(
      center + Offset(-width * .12, -height / 2 + 5),
      center + Offset(width * .12, -height / 2 + 5),
      _stroke(color, 1.5),
    );
    canvas.drawCircle(
      center + Offset(0, height / 2 - 5),
      1.3,
      Paint()..color = color,
    );
  }

  void _link(Canvas canvas, Offset from, Offset to, double t, Color color) {
    final line = Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);
    canvas.drawPath(line, _stroke(pending.withValues(alpha: .16), 1.5));
    final reach = AppMotion.easeOut.transform(_span(t, .12, .55));
    final metric = line.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * reach),
      _stroke(color, 2.4),
    );
    final pulse = _span(t, .4, .75);
    if (pulse > 0 && pulse < 1) {
      final point = Offset.lerp(from, to, pulse)!;
      canvas.drawCircle(point, 4, Paint()..color = accent);
      canvas.drawCircle(
        point,
        8,
        Paint()..color = accent.withValues(alpha: .12),
      );
    }
  }

  void _check(Canvas canvas, Offset center, double t) {
    final arrive = AppMotion.easeOut.transform(_span(t, .55, .78));
    if (arrive <= 0) return;
    final radius = 16 * arrive;
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = accent.withValues(alpha: .12),
    );
    canvas.drawCircle(
      center,
      radius,
      _stroke(accent.withValues(alpha: arrive), 1.5),
    );
    final tick = Path()
      ..moveTo(center.dx - 7, center.dy)
      ..lineTo(center.dx - 2, center.dy + 5)
      ..lineTo(center.dx + 8, center.dy - 5);
    final metric = tick.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * _span(t, .64, .9)),
      _stroke(accent, 2.5),
    );
    final halo = _span(t, .78, 1);
    if (halo > 0 && halo < 1) {
      canvas.drawCircle(
        center,
        20 + halo * 23,
        _stroke(accent.withValues(alpha: (1 - halo) * .4), 1.5),
      );
    }
  }

  @override
  bool shouldRepaint(_NetworkPainter old) =>
      old.progress != progress ||
      old.hotspot != hotspot ||
      old.accent != accent ||
      old.pending != pending;
}
