import 'dart:math';

import 'package:flutter/material.dart';

import 'onboarding_palette.dart';

/// The persistent world the onboarding journey rides through: a layered
/// horizon that is always quietly *travelling*, and whose time of day is a
/// continuous, animatable quantity.
///
/// Back to front: a sky that lerps warm-day → cool-night on [dayNight], a sun
/// that arcs down past the ridge while a moon rises to take its place (with
/// stars fading in as night falls), three parallax mountain silhouettes swaying
/// on the slow [drift] clock, and a foreground ground band whose dashes stream
/// by on the continuous [scroll] clock — the constant motion cue that says
/// "you're moving toward being on air."
///
/// [dayNight] (0 = full day, 1 = full night) is driven by the page as an
/// animation, so choosing Day/Night on the tune beat plays a real sunrise /
/// sunset rather than snapping. Stateless and pointer-transparent; the page
/// owns every clock so the scene stays in lockstep with the radio and HUD.
class HorizonScene extends StatelessWidget {
  /// 0..1 slow ambient loop — parallax sway and the celestial bodies' glow.
  final Animation<double> drift;

  /// 0..1 continuous loop — streams the foreground ground dashes.
  final Animation<double> scroll;

  /// 0 = day, 1 = night. Animatable; the scene renders every value in between.
  final Animation<double> dayNight;

  const HorizonScene({
    super.key,
    required this.drift,
    required this.scroll,
    required this.dayNight,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([drift, scroll, dayNight]),
          builder: (_, _) => CustomPaint(
            size: Size.infinite,
            painter: _HorizonPainter(
              drift: drift.value,
              scroll: scroll.value,
              dn: dayNight.value.clamp(0.0, 1.0),
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizonPainter extends CustomPainter {
  final double drift;
  final double scroll;

  /// 0 = day, 1 = night.
  final double dn;

  _HorizonPainter({
    required this.drift,
    required this.scroll,
    required this.dn,
  });

  /// Fraction of height where sky meets foreground.
  static const _horizon = 0.66;

  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * _horizon;
    final d = 2 * pi * drift;

    _paintSky(canvas, size, horizonY);
    // Stars sit behind the bodies but in front of the sky wash.
    if (dn > 0.02) _paintStars(canvas, size, horizonY);
    // Sun (fades out as night falls) then moon (fades in) — both occluded by
    // the ground band once they dip below the ridge, so they truly set/rise.
    _paintSun(canvas, size, d);
    _paintMoon(canvas, size, d);
    _paintRidges(canvas, size, horizonY, d);
    _paintGround(canvas, size, horizonY);
  }

  // ── Sky: vertical wash lerped between day and night, warm at the ridge ─────

  void _paintSky(Canvas canvas, Size size, double horizonY) {
    final top = Color.lerp(Onb.dayTop, Onb.nightTop, dn)!;
    final mid = Color.lerp(Onb.dayMid, Onb.nightMid, dn)!;
    final horizon = Color.lerp(Onb.dayHorizon, Onb.nightHorizon, dn)!;
    final rect = Rect.fromLTWH(0, 0, size.width, horizonY + 2);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, mid, horizon],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(rect),
    );
  }

  // ── Sun: sits low over the ridge at day, sinks down-right and sets ─────────
  //
  // Bodies ride a low arc in the open sky band just above the mountains — the
  // strip that stays visible below the beat panels — so the sunset/sunrise
  // actually plays on screen rather than hiding behind the HUD.

  void _paintSun(Canvas canvas, Size size, double d) {
    if (dn > 0.80) return;
    final center = Offset(
      size.width * (0.60 + 0.06 * dn), // drifts right as it sets
      size.height * (0.455 + 0.33 * dn) + 3 * sin(d),
    );
    final r = size.shortestSide * 0.10;
    // Warmer/redder as it approaches the horizon (dusk).
    final core = Color.lerp(const Color(0xFFFFE8B0), const Color(0xFFFF9A4D), dn)!;
    final halo = Color.lerp(const Color(0xFFFFC876), Onb.amber, dn)!;
    final vis = (1 - dn / 0.80).clamp(0.0, 1.0);
    _celestial(canvas, center, r, core, halo, vis, craters: false, d: d);
  }

  // ── Moon: below the ridge at day, rises up-left as night falls ─────────────

  void _paintMoon(Canvas canvas, Size size, double d) {
    if (dn < 0.20) return;
    final center = Offset(
      size.width * (0.38 - 0.04 * (1 - dn)),
      size.height * (0.785 - 0.33 * dn) + 3 * sin(d + 1),
    );
    final r = size.shortestSide * 0.095;
    const core = Color(0xFFECF1F6);
    final vis = ((dn - 0.20) / 0.35).clamp(0.0, 1.0);
    _celestial(canvas, center, r, core, Onb.text, vis, craters: true, d: d);
  }

  void _celestial(
    Canvas canvas,
    Offset center,
    double r,
    Color core,
    Color halo,
    double vis, {
    required bool craters,
    required double d,
  }) {
    if (vis <= 0.01) return;
    final a = (vis * 255).toInt();
    // Bloom halo.
    canvas.drawCircle(
      center,
      r * 3.6,
      Paint()
        ..shader = RadialGradient(
          colors: [halo.withAlpha((70 * vis).toInt()), halo.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: center, radius: r * 3.6)),
    );
    // Disc.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.3),
          colors: [
            Color.lerp(core, Colors.white, 0.4)!.withAlpha(a),
            core.withAlpha(a),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
    if (craters) {
      final c = Onb.textDim.withAlpha((70 * vis).toInt());
      canvas.drawCircle(center + Offset(-r * 0.3, -r * 0.2), r * 0.22, Paint()..color = c);
      canvas.drawCircle(center + Offset(r * 0.35, r * 0.15), r * 0.15, Paint()..color = c);
      canvas.drawCircle(center + Offset(r * 0.05, r * 0.45), r * 0.1, Paint()..color = c);
    }
  }

  // ── Stars: fixed scatter, twinkling; alpha rises with night ────────────────

  void _paintStars(Canvas canvas, Size size, double horizonY) {
    final rng = Random(7);
    final paint = Paint()..color = Colors.white;
    final night = Curves.easeIn.transform(dn);
    for (var i = 0; i < 46; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * horizonY * 0.92;
      final phase = rng.nextDouble() * 2 * pi;
      final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * sin(2 * pi * drift + phase));
      // Fade stars out as they near the ridgeline haze.
      final vFade = (1 - y / (horizonY * 0.92)).clamp(0.0, 1.0);
      paint.color = Colors.white.withAlpha((165 * twinkle * vFade * night).toInt());
      canvas.drawCircle(Offset(x, y), rng.nextDouble() < 0.15 ? 1.4 : 0.9, paint);
    }
  }

  // ── Parallax ridges: three silhouettes, hazier & higher toward the back ────

  void _paintRidges(Canvas canvas, Size size, double horizonY, double d) {
    // Day ranges are hazy and light; night ranges sink to near-black. Each
    // pans by its own small amount on the drift clock for parallax depth.
    final specs = <(_RidgeSpec, Color, Color, double)>[
      (
        const _RidgeSpec(seed: 3, base: 0.30, amp: 0.11, roughness: 3.1),
        const Color(0xFFB9A48C), // far, day (hazy warm)
        const Color(0xFF161C23), // far, night
        size.width * 0.015,
      ),
      (
        const _RidgeSpec(seed: 11, base: 0.16, amp: 0.16, roughness: 2.3),
        const Color(0xFF8F7A64),
        const Color(0xFF10151B),
        -size.width * 0.025,
      ),
      (
        const _RidgeSpec(seed: 23, base: 0.02, amp: 0.20, roughness: 1.7),
        const Color(0xFF5F5040),
        const Color(0xFF080B0F),
        size.width * 0.035,
      ),
    ];

    for (final (spec, dayCol, nightCol, pan) in specs) {
      final color = Color.lerp(dayCol, nightCol, dn)!;
      final path = Path();
      final ridgeTop = horizonY * (1 - spec.base);
      final offsetX = pan * sin(d);
      const steps = 40;
      path.moveTo(-4, size.height);
      for (var i = 0; i <= steps; i++) {
        final fx = i / steps;
        final x = fx * (size.width + 8) - 4;
        final n = _noise(fx, spec);
        final y = ridgeTop - spec.amp * horizonY * n;
        path.lineTo(x + offsetX, y);
      }
      path.lineTo(size.width + 4, size.height);
      path.close();
      canvas.drawPath(path, Paint()..color = color);
    }
  }

  double _noise(double fx, _RidgeSpec spec) {
    final r = Random(spec.seed);
    var v = 0.0;
    var amp = 1.0;
    var totalAmp = 0.0;
    var freq = spec.roughness;
    for (var o = 0; o < 4; o++) {
      final phase = r.nextDouble() * 2 * pi;
      v += amp * (0.5 + 0.5 * sin(2 * pi * freq * fx + phase));
      totalAmp += amp;
      amp *= 0.55;
      freq *= 1.9;
    }
    return v / totalAmp;
  }

  // ── Ground: foreground band with streaming dashes for travel ───────────────

  void _paintGround(Canvas canvas, Size size, double horizonY) {
    final w = size.width;
    final h = size.height;
    final ground = Color.lerp(const Color(0xFF3B2E22), const Color(0xFF05070A), dn)!;
    final rect = Rect.fromLTWH(0, horizonY, w, h - horizonY);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(ground, Onb.amber, 0.08)!, ground],
        ).createShader(rect),
    );
    // Edge highlight right at the horizon lip.
    canvas.drawRect(
      Rect.fromLTWH(0, horizonY - 1, w, 2),
      Paint()..color = Onb.amber.withAlpha(60),
    );

    // Streaming dashes: two rows, the lower one bigger and faster so the
    // ground reads as rushing past underfoot.
    void dashRow(double yFrac, double period, double dashW, double speed, int alpha) {
      final y = horizonY + (h - horizonY) * yFrac;
      final shift = (scroll * speed * period) % period;
      final paint = Paint()..color = Onb.amber.withAlpha(alpha);
      for (double x = -period + shift; x < w + period; x += period) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, dashW, 3),
            const Radius.circular(1.5),
          ),
          paint,
        );
      }
    }

    dashRow(0.42, 52, 24, 1.0, 85);
    dashRow(0.72, 78, 40, 1.6, 120);
  }

  @override
  bool shouldRepaint(_HorizonPainter old) =>
      old.drift != drift || old.scroll != scroll || old.dn != dn;
}

class _RidgeSpec {
  final int seed;

  /// Ridge top as a fraction above the horizon (0 = at horizon).
  final double base;

  /// Peak height as a fraction of the sky band.
  final double amp;

  /// Base spatial frequency — higher = more, sharper peaks.
  final double roughness;

  const _RidgeSpec({
    required this.seed,
    required this.base,
    required this.amp,
    required this.roughness,
  });
}
