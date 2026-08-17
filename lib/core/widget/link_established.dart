import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/theme_service.dart';

/// The moment two devices become one channel.
///
/// Replaces the check-in-a-circle that Bluetooth, hotspot and the guest link
/// each had their own copy of. That check said "done"; it did not say *what*
/// was done, and it was the one screen in the app where something genuinely
/// worth celebrating had just happened — two phones found each other with no
/// router, no account and no internet.
///
/// So the animation tells that story instead of asserting it: two peers close
/// on each other, a beam locks between them and carries a pulse, the pair
/// resolves into a single ring, the check strokes in, and one broadcast halo
/// goes out. Radio language throughout, matching the joiner radar and host
/// beacon the user was watching a second earlier — this is those visuals
/// resolving, not a different idea arriving.
///
/// ## Timing is not free here
///
/// All three call sites wait exactly 900 ms before navigating to the channel,
/// and that budget was chosen for the user, not the animation: this is an app
/// people start with gloves on at the side of a road. The whole sequence
/// therefore lands by [_sequenceMs] with the halo still fading, rather than
/// asking for a longer wait. Nothing here is worth an extra half second
/// between a rider and their channel.
///
/// ## Why a painter rather than composed widgets
///
/// It has to hold 60 fps on a Galaxy S8+ (Mali-G71), which rules out the
/// obvious approach — a stack of `AnimatedContainer`s with `boxShadow` glows,
/// where every frame is a mask blur per layer. One painter drawing a dozen
/// primitives costs a fraction of that, glows are two concentric strokes
/// rather than a real blur, and the whole thing repaints inside a single
/// [RepaintBoundary].
class LinkEstablished extends StatefulWidget {
  const LinkEstablished({super.key, required this.label, this.detail});

  /// "Connected" — the headline.
  final String label;

  /// Optional second line: who, or over what.
  final String? detail;

  /// How long a caller should keep this on screen before navigating away.
  ///
  /// Twenty milliseconds clear of [_sequenceMs], so the sequence always lands.
  /// Exposed because every connect page has to know it, and three copies of a
  /// bare `900` cannot be kept in step with an animation length none of them
  /// can see — the first thing to go wrong would be someone lengthening the
  /// choreography and leaving every call site cutting it off.
  static const hold = Duration(milliseconds: _sequenceMs + 200);

  @override
  State<LinkEstablished> createState() => _LinkEstablishedState();
}

/// Total choreography, comfortably inside the 900 ms the call sites allow.
const _sequenceMs = 1000;

class _LinkEstablishedState extends State<LinkEstablished>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _sequenceMs),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Read through the theme listenable rather than straight off AppColors:
    // this subtree survives the theme-change re-key, and a painter holding
    // colours captured at construction would keep painting the old palette.
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (context, _, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: const Size(180, 132),
                painter: _LinkPainter(
                  progress: _c,
                  accent: AppColors.green,
                  peer: AppColors.amber,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _Caption(progress: _c, label: widget.label, detail: widget.detail),
          ],
        ),
      ),
    );
  }
}

/// Headline and detail, rising as the ring resolves.
///
/// Its own widget so the text subtree is not rebuilt by the painter's ticker —
/// only the opacity/offset wrapper animates, and the [Text] children are
/// passed through as a prebuilt child.
class _Caption extends StatelessWidget {
  const _Caption({required this.progress, required this.label, this.detail});

  final Animation<double> progress;
  final String label;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );

    return AnimatedBuilder(
      animation: progress,
      builder: (context, child) {
        final t = _span(progress.value, 0.62, 1.0);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 10 * (1 - t)),
            child: child,
          ),
        );
      },
      child: text,
    );
  }
}

/// Normalised progress of one beat: 0 before [start], 1 after [end].
double _span(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);

class _LinkPainter extends CustomPainter {
  _LinkPainter({
    required this.progress,
    required this.accent,
    required this.peer,
  }) : super(repaint: progress);

  final Animation<double> progress;

  /// Success colour — the ring, the check, the halo.
  final Color accent;

  /// The two peers before they became one link. Amber is the app's own
  /// colour, so the sequence reads as Tark's two radios closing on each other
  /// and *becoming* the green of a working link.
  final Color peer;

  // Beat boundaries, as fractions of the whole sequence.
  static const _approach = (0.0, 0.34);
  static const _beam = (0.20, 0.58);
  static const _ring = (0.46, 0.76);
  static const _check = (0.62, 0.94);
  static const _halo = (0.66, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    final center = Offset(size.width / 2, size.height / 2);
    // Peers start near the edges and close to a small gap either side.
    final approach = Curves.easeOutCubic.transform(
      _span(t, _approach.$1, _approach.$2),
    );
    final spread = 74.0 - 48.0 * approach;

    _paintHalo(canvas, center, t);
    _paintBeam(canvas, center, spread, t);
    _paintPeers(canvas, center, spread, approach, t);
    _paintRing(canvas, center, t);
    _paintCheck(canvas, center, t);
  }

  /// One ring going out — the channel announcing itself.
  void _paintHalo(Canvas canvas, Offset center, double t) {
    final h = _span(t, _halo.$1, _halo.$2);
    if (h <= 0 || h >= 1) return;
    final eased = Curves.easeOutCubic.transform(h);
    canvas.drawCircle(
      center,
      26 + 34 * eased,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * (1 - eased)
        ..color = accent.withValues(alpha: 0.45 * (1 - eased)),
    );
  }

  /// The link itself: a line drawn outward from the centre, then a pulse
  /// running along it. The pulse is what makes this read as a connection
  /// rather than a drawn shape — something travels.
  void _paintBeam(Canvas canvas, Offset center, double spread, double t) {
    final b = _span(t, _beam.$1, _beam.$2);
    if (b <= 0) return;
    final reach = spread * Curves.easeOutCubic.transform(b);
    final left = center.translate(-reach, 0);
    final right = center.translate(reach, 0);

    // Fades out as the ring takes over: the two peers have become one thing,
    // so the line between them stops being the subject.
    final fade = 1 - _span(t, _ring.$1, _ring.$2);
    canvas.drawLine(
      left,
      right,
      Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = peer.withValues(alpha: 0.5 * fade),
    );

    // Two dots converging on the middle — the handshake, one from each end.
    final pulse = _span(t, 0.26, 0.56);
    if (pulse > 0 && pulse < 1 && fade > 0) {
      final travel = Curves.easeInOut.transform(pulse);
      final alpha = 0.9 * (1 - travel) * fade;
      for (final side in const [-1.0, 1.0]) {
        canvas.drawCircle(
          center.translate(side * reach * (1 - travel), 0),
          2.5,
          Paint()..color = peer.withValues(alpha: alpha),
        );
      }
    }
  }

  /// The two radios, closing in and handing off to the ring.
  void _paintPeers(
    Canvas canvas,
    Offset center,
    double spread,
    double approach,
    double t,
  ) {
    if (approach <= 0) return;
    // Gone by the time the ring is established — they have merged into it.
    final alpha = (1 - _span(t, 0.46, 0.66)) * approach;
    if (alpha <= 0) return;

    for (final side in const [-1.0, 1.0]) {
      final at = center.translate(side * spread, 0);
      canvas.drawCircle(
        at,
        7,
        Paint()..color = peer.withValues(alpha: 0.18 * alpha),
      );
      canvas.drawCircle(
        at,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = peer.withValues(alpha: 0.95 * alpha),
      );
    }
  }

  /// The ring, sweeping closed clockwise from the top rather than fading in —
  /// a dial coming round to a lock, which is the gesture the rest of the app's
  /// radio imagery uses.
  void _paintRing(Canvas canvas, Offset center, double t) {
    final r = _span(t, _ring.$1, _ring.$2);
    if (r <= 0) return;
    final swept = Curves.easeOutCubic.transform(r);
    const radius = 26.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = accent.withValues(alpha: 0.10 * swept),
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * swept,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );
    // Glow without a blur: one wider, fainter stroke outside the ring. On the
    // target hardware a real MaskFilter here is the difference between 60 and
    // 40 fps, and at this size nobody can tell.
    if (swept >= 1) {
      canvas.drawCircle(
        center,
        radius + 2.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = accent.withValues(alpha: 0.16),
      );
    }
  }

  /// The check, stroked along its own path rather than popped in — the last
  /// beat of a sequence, not a stamp.
  void _paintCheck(Canvas canvas, Offset center, double t) {
    final c = Curves.easeOutCubic.transform(_span(t, _check.$1, _check.$2));
    if (c <= 0) return;

    final path = Path()
      ..moveTo(center.dx - 9, center.dy + 1)
      ..lineTo(center.dx - 2.5, center.dy + 7.5)
      ..lineTo(center.dx + 10, center.dy - 6);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = accent;

    if (c >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // Two short segments, so extracting a partial path per frame is a handful
    // of arithmetic rather than anything worth caching.
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * c), paint);
    }
  }

  @override
  bool shouldRepaint(_LinkPainter old) =>
      old.accent != accent || old.peer != peer;
}
