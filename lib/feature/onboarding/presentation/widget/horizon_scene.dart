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
///
/// This layer repaints on every frame the journey is on screen, so almost
/// nothing in it is allowed to be computed per frame. The ridge silhouettes and
/// the star scatter are cached against the layout size ([_Geometry]) and every
/// gradient shader against the size *and* the time of day ([_Tint]); a steady
/// frame then costs three `drawPath`s, ~50 dashes and the star alphas. Only
/// while the sunrise/sunset is actually playing does the shader set rebuild.
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
      // Two layers, not one, because their clocks move at wildly different
      // speeds. Everything above the ridgeline only moves on [drift] — a 12s
      // loop that pans the ranges by about a fiftieth of a pixel per frame —
      // while the ground dashes stream on [scroll] and genuinely need every
      // frame. Painting them together meant re-rasterising the whole screen at
      // 60fps to animate motion nobody can see.
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([drift, dayNight]),
              builder: (_, _) => CustomPaint(
                size: Size.infinite,
                painter: _SkyPainter(
                  drift: drift.value,
                  dn: dayNight.value.clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: Listenable.merge([scroll, dayNight]),
              builder: (_, _) => CustomPaint(
                size: Size.infinite,
                painter: _GroundPainter(
                  scroll: scroll.value,
                  dn: dayNight.value.clamp(0.0, 1.0),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fraction of height where sky meets foreground.
const _horizon = 0.66;

/// Sky, stars, sun, moon and ridges — everything driven by the slow drift clock.
///
/// The drift is *quantised* before it reaches the canvas. Nothing up here moves
/// faster than a fifth of a pixel per frame (the widest ridge pan is ~13px over
/// six seconds), so resolving it at 20fps is visually identical and costs a
/// third of the raster work. [shouldRepaint] is where that happens: the widget
/// still rebuilds 60 times a second, but two out of three of those rebuilds
/// find nothing has changed and skip the repaint entirely.
class _SkyPainter extends CustomPainter {
  final double drift;

  /// 0 = day, 1 = night.
  final double dn;

  _SkyPainter({required double drift, required this.dn})
    : drift = (drift * _steps).floorToDouble() / _steps;

  /// Drift samples per loop. The loop is 12s, so 240 ≈ 20fps.
  static const _steps = 240;

  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * _horizon;
    final d = 2 * pi * drift;
    final geo = _Geometry.of(size, horizonY);
    final tint = _Tint.of(size, horizonY, dn);

    canvas.drawRect(geo.skyRect, tint.sky);
    // Stars sit behind the bodies but in front of the sky wash.
    if (dn > 0.02) _paintStars(canvas, geo);
    // Sun (fades out as night falls) then moon (fades in) — both occluded by
    // the ground band once they dip below the ridge, so they truly set/rise.
    // The gentle bob rides the canvas rather than the body's centre, so the
    // radial shaders stay valid (and cached) frame to frame.
    _paintBody(canvas, tint.sun, 3 * sin(d));
    _paintBody(canvas, tint.moon, 3 * sin(d + 1));
    _paintRidges(canvas, geo, tint, d);
  }

  // ── Celestial bodies ──────────────────────────────────────────────────────

  void _paintBody(Canvas canvas, _Body? body, double bob) {
    if (body == null) return;
    canvas.save();
    canvas.translate(0, bob);
    canvas.drawCircle(body.center, body.haloRadius, body.halo);
    canvas.drawCircle(body.center, body.radius, body.disc);
    for (final (offset, r) in body.craters) {
      canvas.drawCircle(body.center + offset, r, body.craterPaint!);
    }
    canvas.restore();
  }

  // ── Stars: fixed scatter, twinkling; alpha rises with night ────────────────

  void _paintStars(Canvas canvas, _Geometry geo) {
    final paint = Paint();
    final night = Curves.easeIn.transform(dn);
    final phase = 2 * pi * drift;
    for (final star in geo.stars) {
      final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * sin(phase + star.phase));
      paint.color = Colors.white.withAlpha(
        (165 * twinkle * star.vFade * night).toInt(),
      );
      canvas.drawCircle(star.at, star.radius, paint);
    }
  }

  // ── Parallax ridges: three silhouettes, hazier & higher toward the back ────

  void _paintRidges(Canvas canvas, _Geometry geo, _Tint tint, double d) {
    // Each range pans by its own small amount on the drift clock for parallax
    // depth. The silhouette itself never changes, so it is a cached path shifted
    // by the canvas rather than 40 fractal-noise samples per range per frame.
    final sway = sin(d);
    for (var i = 0; i < geo.ridges.length; i++) {
      canvas.save();
      canvas.translate(geo.ridgePans[i] * sway, 0);
      canvas.drawPath(geo.ridges[i], tint.ridges[i]);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => old.drift != drift || old.dn != dn;
}

/// The foreground band and its streaming dashes — the scene's one genuinely
/// fast-moving element, and the only reason any of this needs 60fps.
///
/// Drawn over the sky layer, which is also what occludes the sun and moon as
/// they dip below the ridge.
class _GroundPainter extends CustomPainter {
  final double scroll;

  /// 0 = day, 1 = night.
  final double dn;

  const _GroundPainter({required this.scroll, required this.dn});

  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * _horizon;
    final geo = _Geometry.of(size, horizonY);
    final tint = _Tint.of(size, horizonY, dn);
    final w = size.width;
    final h = size.height;
    canvas.drawRect(geo.groundRect, tint.ground);
    // Edge highlight right at the horizon lip.
    canvas.drawRect(Rect.fromLTWH(0, horizonY - 1, w, 2), tint.horizonLip);

    // Streaming dashes: two rows, the lower one bigger and faster so the
    // ground reads as rushing past underfoot.
    //
    // [cycles] is the whole number of periods a row advances per scroll loop.
    // Keeping it an integer makes the shift continuous across the controller's
    // 1→0 wrap; the old fractional speeds (e.g. 1.6) left the offset snapping
    // back mid-stream every loop, so the road looked like it jumped to the
    // start every few seconds.
    void dashRow(double yFrac, double period, double dashW, int cycles, Paint paint) {
      final y = horizonY + (h - horizonY) * yFrac;
      final shift = (scroll * cycles % 1.0) * period;
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

    dashRow(0.42, 52, 24, 1, tint.dashNear);
    dashRow(0.72, 78, 40, 2, tint.dashFar);
  }

  @override
  bool shouldRepaint(_GroundPainter old) =>
      old.scroll != scroll || old.dn != dn;
}

// ── Cached scene pieces ─────────────────────────────────────────────────────
//
// The painter is rebuilt every frame (it has to be — it carries the clocks),
// so these caches are static. Only one horizon is ever on screen, so a
// single-entry cache per kind is all that's needed; a resize or a step of the
// sunrise simply replaces it.

/// Everything that depends only on the layout size: the ridge silhouettes and
/// the star scatter. Rebuilding these per frame cost ~500 `sin` calls and ~120
/// `Random` allocations, for a picture that is identical every time.
class _Geometry {
  final Size size;
  final Rect skyRect;
  final Rect groundRect;
  final List<Path> ridges;
  final List<double> ridgePans;
  final List<_Star> stars;

  const _Geometry({
    required this.size,
    required this.skyRect,
    required this.groundRect,
    required this.ridges,
    required this.ridgePans,
    required this.stars,
  });

  static _Geometry? _cached;

  static _Geometry of(Size size, double horizonY) {
    final hit = _cached;
    if (hit != null && hit.size == size) return hit;
    return _cached = _build(size, horizonY);
  }

  static _Geometry _build(Size size, double horizonY) {
    final ridges = <Path>[];
    final pans = <double>[];
    for (final (spec, pan) in _ridgeSpecs) {
      final ridgeTop = horizonY * (1 - spec.base);
      // Closed just past the horizon, not at the bottom of the screen: the
      // ground band is painted over that region anyway, so filling down to
      // size.height meant three silhouettes each burning a third of a screen
      // of fill rate per frame to draw pixels nobody ever sees.
      final base = horizonY + 3;
      final path = Path()..moveTo(-4, base);
      const steps = 40;
      for (var i = 0; i <= steps; i++) {
        final fx = i / steps;
        final x = fx * (size.width + 8) - 4;
        final y = ridgeTop - spec.amp * horizonY * _noise(fx, spec);
        path.lineTo(x, y);
      }
      path.lineTo(size.width + 4, base);
      path.close();
      ridges.add(path);
      pans.add(size.width * pan);
    }

    final rng = Random(7);
    final starBand = horizonY * 0.92;
    final stars = List<_Star>.generate(46, (_) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * starBand;
      final phase = rng.nextDouble() * 2 * pi;
      final radius = rng.nextDouble() < 0.15 ? 1.4 : 0.9;
      return _Star(
        at: Offset(x, y),
        phase: phase,
        radius: radius,
        // Fade stars out as they near the ridgeline haze.
        vFade: (1 - y / starBand).clamp(0.0, 1.0),
      );
    });

    return _Geometry(
      size: size,
      skyRect: Rect.fromLTWH(0, 0, size.width, horizonY + 2),
      groundRect: Rect.fromLTWH(0, horizonY, size.width, size.height - horizonY),
      ridges: ridges,
      ridgePans: pans,
      stars: stars,
    );
  }

  /// Fractal ridgeline: four octaves of phase-shifted sine.
  static double _noise(double fx, _RidgeSpec spec) {
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
}

class _Star {
  final Offset at;
  final double phase;
  final double radius;
  final double vFade;

  const _Star({
    required this.at,
    required this.phase,
    required this.radius,
    required this.vFade,
  });
}

/// Every colour and shader in the scene, keyed by size *and* time of day. Only
/// rebuilt while a sunrise/sunset is actually playing — the rest of the time
/// this is a straight cache hit and no gradient shader is created at all.
class _Tint {
  final Size size;
  final double dn;
  final Paint sky;
  final Paint ground;
  final Paint horizonLip;
  final List<Paint> ridges;
  final Paint dashNear;
  final Paint dashFar;
  final _Body? sun;
  final _Body? moon;

  const _Tint({
    required this.size,
    required this.dn,
    required this.sky,
    required this.ground,
    required this.horizonLip,
    required this.ridges,
    required this.dashNear,
    required this.dashFar,
    required this.sun,
    required this.moon,
  });

  static _Tint? _cached;

  static _Tint of(Size size, double horizonY, double dn) {
    final hit = _cached;
    if (hit != null && hit.size == size && hit.dn == dn) return hit;
    return _cached = _build(size, horizonY, dn);
  }

  static _Tint _build(Size size, double horizonY, double dn) {
    // Sky: vertical wash lerped between day and night, warm at the ridge.
    final skyRect = Rect.fromLTWH(0, 0, size.width, horizonY + 2);
    final sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(Onb.dayTop, Onb.nightTop, dn)!,
          Color.lerp(Onb.dayMid, Onb.nightMid, dn)!,
          Color.lerp(Onb.dayHorizon, Onb.nightHorizon, dn)!,
        ],
        stops: const [0.0, 0.6, 1.0],
      ).createShader(skyRect);

    final groundRect = Rect.fromLTWH(
      0,
      horizonY,
      size.width,
      size.height - horizonY,
    );
    final groundCol = Color.lerp(
      const Color(0xFF3B2E22),
      const Color(0xFF05070A),
      dn,
    )!;
    final ground = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(groundCol, Onb.amber, 0.08)!, groundCol],
      ).createShader(groundRect);

    // Day ranges are hazy and light; night ranges sink to near-black.
    final ridges = [
      for (final (day, night) in _ridgeColors)
        Paint()..color = Color.lerp(day, night, dn)!,
    ];

    return _Tint(
      size: size,
      dn: dn,
      sky: sky,
      ground: ground,
      horizonLip: Paint()..color = Onb.amber.withAlpha(60),
      ridges: ridges,
      dashNear: Paint()..color = Onb.amber.withAlpha(85),
      dashFar: Paint()..color = Onb.amber.withAlpha(120),
      sun: _sun(size, dn),
      moon: _moon(size, dn),
    );
  }

  // Bodies ride a low arc in the open sky band just above the mountains — the
  // strip that stays visible below the beat panels — so the sunset/sunrise
  // actually plays on screen rather than hiding behind the HUD.

  /// Sits low over the ridge at day, sinks down-right and sets.
  static _Body? _sun(Size size, double dn) {
    if (dn > 0.80) return null;
    final vis = (1 - dn / 0.80).clamp(0.0, 1.0);
    if (vis <= 0.01) return null;
    return _Body.build(
      center: Offset(
        size.width * (0.60 + 0.06 * dn), // drifts right as it sets
        size.height * (0.455 + 0.33 * dn),
      ),
      radius: size.shortestSide * 0.10,
      // Warmer/redder as it approaches the horizon (dusk).
      core: Color.lerp(const Color(0xFFFFE8B0), const Color(0xFFFF9A4D), dn)!,
      halo: Color.lerp(const Color(0xFFFFC876), Onb.amber, dn)!,
      vis: vis,
      craters: false,
    );
  }

  /// Below the ridge at day, rises up-left as night falls.
  static _Body? _moon(Size size, double dn) {
    if (dn < 0.20) return null;
    final vis = ((dn - 0.20) / 0.35).clamp(0.0, 1.0);
    if (vis <= 0.01) return null;
    return _Body.build(
      center: Offset(
        size.width * (0.38 - 0.04 * (1 - dn)),
        size.height * (0.785 - 0.33 * dn),
      ),
      radius: size.shortestSide * 0.095,
      core: const Color(0xFFECF1F6),
      halo: Onb.text,
      vis: vis,
      craters: true,
    );
  }
}

/// A sun or moon with its bloom halo, lit disc and (for the moon) craters,
/// baked into ready-to-draw paints.
class _Body {
  final Offset center;
  final double radius;
  final double haloRadius;
  final Paint halo;
  final Paint disc;
  final Paint? craterPaint;
  final List<(Offset, double)> craters;

  const _Body({
    required this.center,
    required this.radius,
    required this.haloRadius,
    required this.halo,
    required this.disc,
    required this.craterPaint,
    required this.craters,
  });

  static _Body build({
    required Offset center,
    required double radius,
    required Color core,
    required Color halo,
    required double vis,
    required bool craters,
  }) {
    final a = (vis * 255).toInt();
    final haloRadius = radius * 3.6;
    return _Body(
      center: center,
      radius: radius,
      haloRadius: haloRadius,
      halo: Paint()
        ..shader = RadialGradient(
          colors: [halo.withAlpha((70 * vis).toInt()), halo.withAlpha(0)],
        ).createShader(Rect.fromCircle(center: center, radius: haloRadius)),
      disc: Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.3),
          colors: [
            Color.lerp(core, Colors.white, 0.4)!.withAlpha(a),
            core.withAlpha(a),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
      craterPaint: craters
          ? (Paint()..color = Onb.textDim.withAlpha((70 * vis).toInt()))
          : null,
      craters: craters
          ? [
              (Offset(-radius * 0.3, -radius * 0.2), radius * 0.22),
              (Offset(radius * 0.35, radius * 0.15), radius * 0.15),
              (Offset(radius * 0.05, radius * 0.45), radius * 0.1),
            ]
          : const [],
    );
  }
}

/// Far → near. The second value is the pan amplitude as a fraction of width.
const _ridgeSpecs = <(_RidgeSpec, double)>[
  (_RidgeSpec(seed: 3, base: 0.30, amp: 0.11, roughness: 3.1), 0.015),
  (_RidgeSpec(seed: 11, base: 0.16, amp: 0.16, roughness: 2.3), -0.025),
  (_RidgeSpec(seed: 23, base: 0.02, amp: 0.20, roughness: 1.7), 0.035),
];

/// (day, night) silhouette colours, in the same far → near order.
const _ridgeColors = <(Color, Color)>[
  (Color(0xFFB9A48C), Color(0xFF161C23)), // far, hazy warm → near-black
  (Color(0xFF8F7A64), Color(0xFF10151B)),
  (Color(0xFF5F5040), Color(0xFF080B0F)),
];

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
