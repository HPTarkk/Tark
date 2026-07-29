import 'dart:math';

import 'package:flutter/widgets.dart';

import 'beat_transition.dart';

/// A **channel retune**: a bright signal bar scans across the panel and the next
/// beat resolves in behind it out of digital static, the way a radio locks onto
/// a new station.
///
/// A luminous scan bar travels across the beat panel in the direction of travel.
/// Ahead of it the outgoing beat still stands; behind it the incoming beat is
/// already *locked in* — crisp, not fading up — but right at the bar a band of
/// static flecks and CRT scanlines shows the new signal resolving, so the change
/// reads as tuning rather than a plain wipe. The bar itself is a live
/// oscilloscope edge (a smooth waveform, tapered clean at both ends by an
/// envelope) with a soft halo, a hot white core and bright crest nodes.
///
/// It is a hard wipe: the two beats occupy complementary regions of the panel
/// and never overlap, so there is zero ghosting. A small opposed parallax on
/// each side adds depth. Resolves to the plain incoming beat at `t == 0/1`.
///
/// ### Cost
///
/// This is the expensive one, and knowingly so — the look *is* the glow. Every
/// frame it re-cuts two 48-segment [ClipPath]s (so both beats are re-recorded,
/// not composited from cache) and strokes four copies of the waveform, three of
/// them through a [MaskFilter] blur. On a modern GPU that is fine. On an older
/// tile-based mobile GPU the blurred strokes alone will miss frame budget, and
/// the clips prevent any raster caching from helping.
///
/// [quality] trades the look down for those devices: [SweepQuality.lite] drops
/// the mask blurs (the halo becomes a wide translucent stroke) and thins the
/// static band, which is most of the cost for a modest loss. If you need
/// something that is fast by construction rather than by dialling back, use
/// `RushTransition` instead.
class SignalSweepTransition extends BeatTransition {
  const SignalSweepTransition({
    this.accent = const Color(0xFFF5853F),
    this.quality = SweepQuality.full,
  });

  /// The colour of the scan bar, its halo and the resolving static.
  final Color accent;

  final SweepQuality quality;

  @override
  Widget build({
    required Widget? leaving,
    required Widget incoming,
    required Animation<double> progress,
    required int direction,
    required TextDirection textDirection,
  }) {
    if (leaving == null) return incoming;
    // Advancing sweeps toward the reading-end of the panel.
    final dir =
        (direction >= 0 ? 1 : -1) *
        (textDirection == TextDirection.ltr ? 1 : -1);
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) => buildSignalSweep(
        leaving: leaving,
        incoming: incoming,
        t: progress.value,
        dir: dir,
        accent: accent,
        quality: quality,
      ),
    );
  }
}

/// How much of the sweep's decoration to render.
enum SweepQuality {
  /// Blurred halo, full static band, CRT scanlines. As designed.
  full,

  /// No `MaskFilter` blur and a thinner static band — roughly half the raster
  /// cost, for older GPUs.
  lite,
}

/// The sweep as a bare function, for callers that already have a `double` clock
/// and do not want the [BeatTransition] wrapper.
Widget buildSignalSweep({
  required Widget? leaving,
  required Widget incoming,
  required double t,
  required int dir,
  Color accent = const Color(0xFFF5853F),
  SweepQuality quality = SweepQuality.full,
}) {
  if (leaving == null || t <= 0.0 || t >= 1.0) return incoming;

  final sweep = _Sweep(t: t, dir: dir);
  final e = sweep.e;
  final inDx = (dir * _parallax * (1 - e)).toDouble();
  final outDx = (-dir * _parallax * e).toDouble();

  return Stack(
    clipBehavior: Clip.none,
    children: [
      // Incoming sizes the stack and is revealed behind the scan bar.
      ClipPath(
        clipper: _SweepClipper(sweep: sweep, reveal: true),
        child: Transform.translate(offset: Offset(inDx, 0), child: incoming),
      ),
      // Outgoing fills that same box, clipped to the not-yet-swept side.
      Positioned.fill(
        child: IgnorePointer(
          child: ClipPath(
            clipper: _SweepClipper(sweep: sweep, reveal: false),
            child: Transform.translate(
              offset: Offset(outDx, 0),
              child: leaving,
            ),
          ),
        ),
      ),
      // Static-resolve band + scanlines (clipped to the incoming side) and the
      // glowing scan bar, all on top.
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _EdgePainter(
              sweep: sweep,
              accent: accent,
              quality: quality,
            ),
          ),
        ),
      ),
    ],
  );
}

const double _parallax = 12; // px each side drifts, opposed
const double _margin = 72; // how far past the panel the bar starts/ends
const double _amp = 16; // waveform amplitude at mid-sweep
const double _staticBand = 46; // px behind the bar where the signal resolves

/// Shared geometry for the scan bar, so the clips, the static band and the
/// glowing stroke all trace the exact same waveform.
class _Sweep {
  final double t;
  final int dir;
  final double e; // eased progress
  final double env; // amplitude envelope: 0 at ends, 1 mid-sweep

  _Sweep({required this.t, required this.dir})
    : e = Curves.easeInOutCubic.transform(t),
      env = sin(pi * t.clamp(0.0, 1.0));

  /// X of the wavy edge at height fraction [ny] (0..1) across a box [w] wide.
  /// A smooth oscilloscope wobble (two low harmonics) — a signal, not a crack.
  double edgeX(double ny, double w) {
    final travel = w + 2 * _margin;
    final base = dir >= 0 ? -_margin + travel * e : (w + _margin) - travel * e;
    final wave =
        sin(ny * 5.0 + t * 6.0) * 0.62 + sin(ny * 11.0 - t * 9.0) * 0.38;
    return base + _amp * env * wave;
  }

  /// The incoming beat lives on the side the scan bar has already cleared.
  bool get revealLeft => dir >= 0;

  /// Which way the already-resolved (incoming) side lies from the bar.
  double get incomingSign => revealLeft ? -1.0 : 1.0;

  /// Path over the incoming (already-swept) region, for clipping the resolve
  /// band and scanlines to just the new signal.
  Path incomingPath(Size size) {
    final w = size.width;
    final h = size.height;
    const steps = 48;
    final p = Path()..moveTo(edgeX(0, w), 0);
    for (var i = 1; i <= steps; i++) {
      final ny = i / steps;
      p.lineTo(edgeX(ny, w), ny * h);
    }
    if (revealLeft) {
      p.lineTo(0, h);
      p.lineTo(0, 0);
    } else {
      p.lineTo(w, h);
      p.lineTo(w, 0);
    }
    return p..close();
  }
}

class _SweepClipper extends CustomClipper<Path> {
  final _Sweep sweep;
  final bool reveal;

  const _SweepClipper({required this.sweep, required this.reveal});

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;
    const steps = 48;
    final path = Path()..moveTo(sweep.edgeX(0, w), 0);
    for (var i = 1; i <= steps; i++) {
      final ny = i / steps;
      path.lineTo(sweep.edgeX(ny, w), ny * h);
    }
    // Close along whichever vertical side this region belongs to.
    final left = sweep.revealLeft == reveal;
    if (left) {
      path.lineTo(0, h);
      path.lineTo(0, 0);
    } else {
      path.lineTo(w, h);
      path.lineTo(w, 0);
    }
    return path..close();
  }

  @override
  bool shouldReclip(_SweepClipper old) =>
      old.sweep.t != sweep.t ||
      old.sweep.dir != sweep.dir ||
      old.reveal != reveal;
}

class _EdgePainter extends CustomPainter {
  final _Sweep sweep;
  final Color accent;
  final SweepQuality quality;

  const _EdgePainter({
    required this.sweep,
    required this.accent,
    required this.quality,
  });

  bool get _full => quality == SweepQuality.full;

  @override
  void paint(Canvas canvas, Size size) {
    if (sweep.t <= 0.02 || sweep.t >= 0.98) return;
    final w = size.width;
    final h = size.height;
    final glow = sweep.env;
    final white = Color.lerp(accent, const Color(0xFFFFFFFF), 0.7)!;

    // ── The new signal resolving: static flecks + CRT scanlines, clipped to
    //    the incoming side so it only dusts the freshly-tuned beat. ───────────
    canvas.save();
    canvas.clipPath(sweep.incomingPath(size));

    if (_full) {
      // Faint scanlines that lock in (fade as the retune completes).
      final scan = Paint()
        ..color = accent.withValues(alpha: 0.05 * glow)
        ..strokeWidth = 1;
      for (double y = 0; y < h; y += 4) {
        canvas.drawLine(Offset(0, y), Offset(w, y), scan);
      }
    }

    // A band of static hugging the bar — brightest at the edge, dissolving as
    // the signal settles a few px in. Seeded on t so it flickers frame-to-frame.
    final rng = Random((sweep.t * 120).floor() * 2654435761 & 0x7fffffff);
    final fleck = Paint()..strokeCap = StrokeCap.round;
    final flecks = _full ? 70 : 26;
    for (var i = 0; i < flecks; i++) {
      final ny = rng.nextDouble();
      final dist = rng.nextDouble() * _staticBand; // px into the incoming side
      final x = sweep.edgeX(ny, w) + sweep.incomingSign * dist;
      if (x < 0 || x > w) continue;
      final y = ny * h;
      final near = 1 - dist / _staticBand; // 1 at the bar, 0 deep in
      final a = (near * near * (0.5 + 0.5 * rng.nextDouble()) * glow).clamp(
        0.0,
        1.0,
      );
      fleck
        ..color = (rng.nextDouble() < 0.3 ? white : accent).withValues(alpha: a)
        ..strokeWidth = 1 + rng.nextDouble() * 1.4;
      final len = 2 + rng.nextDouble() * 6;
      canvas.drawLine(Offset(x - len / 2, y), Offset(x + len / 2, y), fleck);
    }
    canvas.restore();

    // ── The scan bar itself, over everything. ────────────────────────────────
    const steps = 64;
    final path = Path()..moveTo(sweep.edgeX(0, w), 0);
    for (var i = 1; i <= steps; i++) {
      final ny = i / steps;
      path.lineTo(sweep.edgeX(ny, w), ny * h);
    }

    // Wide soft halo. Without a blur budget it degrades to a wide, very
    // translucent stroke — same silhouette, no offscreen pass.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 34
        ..color = accent.withValues(alpha: (_full ? 0.12 : 0.07) * glow)
        ..maskFilter = _full
            ? const MaskFilter.blur(BlurStyle.normal, 14)
            : null,
    );
    // Inner glow.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..color = accent.withValues(alpha: (_full ? 0.45 : 0.28) * glow)
        ..maskFilter = _full ? const MaskFilter.blur(BlurStyle.normal, 4) : null,
    );
    // Amber body.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: 0.9 * glow),
    );
    // Hot white core.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = white.withValues(alpha: 0.95 * glow),
    );
    // Bright crest nodes — the "live signal" read.
    final dot = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.9 * glow);
    final halo = Paint()
      ..color = accent.withValues(alpha: (_full ? 0.5 : 0.3) * glow)
      ..maskFilter = _full ? const MaskFilter.blur(BlurStyle.normal, 3) : null;
    for (var i = 0; i <= 6; i++) {
      final ny = i / 6;
      final c = Offset(sweep.edgeX(ny, w), ny * h);
      canvas.drawCircle(c, 3.4, halo);
      canvas.drawCircle(c, 1.7, dot);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.sweep.t != sweep.t ||
      old.sweep.dir != sweep.dir ||
      old.accent != accent ||
      old.quality != quality;
}
