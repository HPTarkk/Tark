import 'dart:math';

import 'package:flutter/widgets.dart';

/// The choreography of one beat change, solved once per frame and shared by
/// every piece that draws it — the two panels, the wind, the trails and the
/// lock reticle all read the same numbers, so nothing can drift out of sync.
///
/// The handover is staged rather than a single slide, which is what makes it
/// feel deliberate instead of hurried:
///
/// ```text
/// t   0.00      0.15         0.46   0.58        0.88    1.00
///     |  CHARGE  |   THROW    | TRANSIT |  ARRIVE  | LOCK |
///     └ winds up ┘            └ empty  ┘          └ settles
/// ```
///
/// * **CHARGE** — the outgoing panel pulls *back* against the direction of
///   travel and squashes along it. Classic anticipation: the eye reads the
///   wind-up and knows what is about to happen before it happens.
/// * **THROW** — it accelerates off the end edge, stretching along its travel
///   and turning away into perspective.
/// * **TRANSIT** — a real, deliberate gap with nothing on the stage but the
///   wind and the reticle closing in. This is the beat that stops the change
///   feeling rushed; without it the two panels just trade places.
/// * **ARRIVE** — the incoming panel decelerates in from the start edge.
/// * **LOCK** — it settles on a damped bounce while the reticle snaps onto its
///   corners and a shockwave pulses out. The arrival gets an ending.
@immutable
class Stage {
  /// Raw 0..1 clock. Direction of travel is the caller's business — everything
  /// here is a magnitude, so the same numbers drive an LTR and an RTL handover.
  final double t;

  const Stage._(this.t);

  factory Stage(double t) => Stage._(t.clamp(0.0, 1.0));

  // ── Phase boundaries ───────────────────────────────────────────────────────

  static const chargeEnd = 0.30; // the wind-up bell closes here
  static const throwStart = 0.15;
  static const throwEnd = 0.46;
  static const arriveStart = 0.50;
  static const arriveEnd = 0.88;
  static const lockStart = 0.84;

  /// A 0 → 1 → 0 bell over [a]..[b]; 0 outside it.
  static double bell(double t, double a, double b) =>
      sin(pi * ((t - a) / (b - a)).clamp(0.0, 1.0));

  static double _seg(double t, double a, double b, Curve c) =>
      c.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  // ── Outgoing panel ─────────────────────────────────────────────────────────

  /// Wind-up strength, 0 → 1 → 0 across CHARGE.
  double get anticipation => bell(t, 0.0, chargeEnd);

  /// Distance from rest in screen-travel units: 0 at home, 1 fully off the end.
  /// Goes slightly *negative* during CHARGE — that is the pull-back.
  double get exit {
    final fly = _seg(t, throwStart, throwEnd, Curves.easeInCubic);
    return fly - 0.055 * anticipation * (1 - fly);
  }

  double get exitOpacity => 1 - _seg(t, 0.34, 0.48, Curves.easeIn);

  /// How hard the outgoing panel is moving right now, for stretch and wind.
  double get exitSpeed => bell(t, throwStart, throwEnd);

  // ── Incoming panel ─────────────────────────────────────────────────────────

  /// 1 while still off the start edge, 0 once home.
  double get entry => 1 - _seg(t, arriveStart, arriveEnd, Curves.easeOutCubic);

  double get entryOpacity => _seg(t, 0.52, 0.68, Curves.easeOut);

  double get entrySpeed => bell(t, arriveStart, arriveEnd);

  /// Damped bounce as the panel comes to rest — a decaying oscillation over
  /// LOCK, so it lands with weight instead of simply stopping.
  double get settle {
    if (t < lockStart) return 0;
    final u = (t - lockStart) / (1 - lockStart);
    return exp(-5.5 * u) * sin(3 * pi * u);
  }

  // ── Chrome ─────────────────────────────────────────────────────────────────

  /// How much wind is blowing: builds through CHARGE, peaks mid-TRANSIT,
  /// gone by the time the panel locks.
  double get wind => pow(bell(t, 0.04, 0.92), 0.7).toDouble();

  /// Reticle closing on the landing zone, 0 (wide open) → 1 (snapped on).
  double get reticle => _seg(t, 0.40, 0.90, Curves.easeOutCubic);

  /// Reticle visibility — up during TRANSIT, out once the panel owns the frame.
  double get reticleAlpha =>
      _seg(t, 0.36, 0.48, Curves.easeOut) * (1 - _seg(t, 0.90, 1.0, Curves.easeIn));

  /// The lock flash and its outward shockwave, 0 → 1 → 0 across LOCK.
  double get impact => bell(t, lockStart, 1.0);

  /// Guide rails the panels ride across the empty stage.
  double get rails =>
      _seg(t, 0.10, 0.30, Curves.easeOut) * (1 - _seg(t, 0.78, 0.94, Curves.easeIn));
}
