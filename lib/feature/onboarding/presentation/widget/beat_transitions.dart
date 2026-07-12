import 'dart:math';

import 'package:flutter/material.dart';

/// Per-boundary transition choreography for the onboarding beats.
///
/// Each of the four step boundaries gets a *distinct* signature motion, so no
/// two advances through the journey ever feel the same:
///
///   0↔1  warp   — fade-through zoom: the old beat rushes off in depth and is
///                 gone before the new one swells up out of the distance
///   1↔2  glide  — filmstrip: both beats travel one screen-width apart in
///                 lockstep, so one slides fully out as the next slides fully in
///   2↔3  flip   — two-phase card flip about the vertical axis
///   3↔4  rise   — fade-through stack-push with an overshoot bloom onto the card
///
/// The guiding rule for "clean" is **no ghosting**: the outgoing and incoming
/// beats never sit visible in the same place at partial opacity. The
/// fade-through pair below schedules the outgoing to finish leaving before the
/// incoming begins arriving; the glide keeps both fully opaque but a full
/// screen-width apart so they simply never overlap. Every transition resolves
/// to the exact identity transform at t == 1.
Widget buildBeatTransition({
  required int gap,
  required int dir,
  required bool leaving,
  required double t,
  required double width,
  required Widget child,
}) {
  switch (gap) {
    case 0:
      return _warp(dir, leaving, t, child);
    case 1:
      return _glide(dir, leaving, t, width, child);
    case 2:
      return _flip(dir, leaving, t, child);
    default:
      return _rise(dir, leaving, t, child);
  }
}

// ── Shared fade-through schedule ────────────────────────────────────────────
// The outgoing beat exits over the first ~half and is fully transparent by
// [_outGone]; the incoming beat is fully transparent until [_inStart] and then
// arrives over the back half. The tiny gap between them is what stops the two
// beats from ghosting through each other.
const double _outGone = 0.42;
const double _inStart = 0.40;

double _exit(double t) => Curves.easeInCubic.transform((t / 0.55).clamp(0.0, 1.0));
double _exitOpacity(double t) => 1 - (t / _outGone).clamp(0.0, 1.0);
double _enter(double t) => Curves.easeOutCubic.transform(
  ((t - _inStart) / (1 - _inStart)).clamp(0.0, 1.0),
);
double _enterOpacity(double t) =>
    Curves.easeOut.transform(((t - _inStart) / 0.5).clamp(0.0, 1.0));

/// 0↔1 — Warp. Fade-through zoom: forward, the old beat rushes toward the
/// viewer and fades before the new one swells up out of depth; back mirrors it.
Widget _warp(int dir, bool leaving, double t, Widget child) {
  if (leaving) {
    final e = _exit(t);
    return Opacity(
      opacity: _exitOpacity(t),
      child: Transform.scale(
        scale: dir > 0 ? 1 + 0.75 * e : 1 - 0.45 * e,
        child: child,
      ),
    );
  }
  final e = _enter(t);
  final from = dir > 0 ? 0.42 : 1.5;
  return Opacity(
    opacity: _enterOpacity(t),
    child: Transform.scale(scale: from + (1 - from) * e, child: child),
  );
}

/// 1↔2 — Glide. A rigid filmstrip: the two beats sit exactly one screen-width
/// apart and translate together, so the outgoing panel slides fully off one
/// edge as the incoming slides in from the other — full opacity, no overlap.
Widget _glide(int dir, bool leaving, double t, double width, Widget child) {
  final e = Curves.easeInOutCubic.transform(t);
  final dx = leaving ? -dir * width * e : dir * width * (1 - e);
  return Transform.translate(offset: Offset(dx, 0), child: child);
}

/// 2↔3 — Flip. A true two-phase card flip: the outgoing beat rotates edge-on
/// through the first half, then the incoming beat rotates in from edge-on
/// through the second, so it reads as one card turning over (already clean —
/// both faces are edge-on and invisible at the midpoint, so they never ghost).
Widget _flip(int dir, bool leaving, double t, Widget child) {
  if (leaving) {
    final e = Curves.easeInCubic.transform((t / 0.5).clamp(0.0, 1.0));
    return Opacity(
      opacity: (1 - e).clamp(0.0, 1.0),
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0013)
          ..rotateY(-dir * (pi / 2) * e),
        child: child,
      ),
    );
  }
  final e = Curves.easeOutCubic.transform(((t - 0.5) / 0.5).clamp(0.0, 1.0));
  return Opacity(
    opacity: e.clamp(0.0, 1.0),
    child: Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0013)
        ..rotateY(dir * (pi / 2) * (1 - e)),
      child: child,
    ),
  );
}

/// 3↔4 — Rise. Fade-through stack-push onto the payoff: the old beat lifts away
/// and fades, then the operator card rises from below with an easeOutBack
/// overshoot and a small scale bloom — landing as the READY stamp hits.
Widget _rise(int dir, bool leaving, double t, Widget child) {
  if (leaving) {
    final e = _exit(t);
    return Opacity(
      opacity: _exitOpacity(t),
      child: Transform.translate(
        offset: Offset(0, -dir * 46 * e),
        child: Transform.scale(scale: 1 - 0.04 * e, child: child),
      ),
    );
  }
  final e = _enter(t);
  final bloom = Curves.easeOutBack.transform(
    ((t - _inStart) / (1 - _inStart)).clamp(0.0, 1.0),
  );
  return Opacity(
    opacity: _enterOpacity(t),
    child: Transform.translate(
      offset: Offset(0, dir * 72 * (1 - e)),
      child: Transform.scale(scale: 0.94 + 0.06 * bloom, child: child),
    ),
  );
}
