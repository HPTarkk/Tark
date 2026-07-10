import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Drives a full-screen circular-reveal transition for theme/locale changes
/// (item 10 — explicitly not a plain cross-fade/AnimatedSwitcher).
///
/// Snapshots the current UI via [repaintBoundaryKey], applies the change
/// underneath (hidden behind the snapshot), then wipes an expanding circular
/// hole from the tap origin through the frozen snapshot to reveal the
/// already-updated live tree — similar to Android's native theme-change
/// ripple. Falls back to an instant, unanimated change when reduced-motion
/// is on or the snapshot can't be captured (e.g. an unsupported web
/// renderer), rather than failing the theme/locale change itself.
abstract final class AppRevealController {
  static final GlobalKey repaintBoundaryKey = GlobalKey();

  static Future<void> reveal({
    required BuildContext context,
    required Offset origin,
    required VoidCallback applyChange,
  }) async {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      applyChange();
      return;
    }

    final renderObject = repaintBoundaryKey.currentContext?.findRenderObject();
    final boundary = renderObject is RenderRepaintBoundary
        ? renderObject
        : null;
    if (boundary == null || !boundary.attached) {
      applyChange();
      return;
    }

    final screenSize = MediaQuery.of(context).size;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;

    ui.Image snapshot;
    try {
      snapshot = await boundary.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      // Some web renderers don't support toImage() — degrade gracefully.
      applyChange();
      return;
    }

    if (!context.mounted) {
      snapshot.dispose();
      applyChange();
      return;
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    final overlay = Overlay.of(context, rootOverlay: true);
    final controller = AnimationController(
      vsync: navigator,
      duration: const Duration(milliseconds: 550),
    );
    final radius = Tween<double>(begin: 0, end: _maxRadius(origin, screenSize))
        .animate(
          CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic),
        );

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: radius,
            builder: (context, _) => ClipPath(
              clipper: _CircleRevealClipper(
                center: origin,
                radius: radius.value,
              ),
              child: RawImage(
                image: snapshot,
                width: screenSize.width,
                height: screenSize.height,
                fit: BoxFit.fill,
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    // Apply the change now, hidden underneath the frozen snapshot — by the
    // time the reveal animation starts peeling it away, the live tree below
    // has already picked up the new theme/locale.
    applyChange();
    await WidgetsBinding.instance.endOfFrame;

    try {
      await controller.forward();
    } finally {
      entry.remove();
      controller.dispose();
      snapshot.dispose();
    }
  }

  static double _maxRadius(Offset origin, Size size) {
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _CircleRevealClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  const _CircleRevealClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    return Path.combine(PathOperation.difference, full, hole);
  }

  @override
  bool shouldReclip(_CircleRevealClipper old) =>
      old.radius != radius || old.center != center;
}
