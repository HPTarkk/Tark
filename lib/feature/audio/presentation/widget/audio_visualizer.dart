import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Loudest signal the auto-gain will still stretch to full scale. Speech peaks
/// land around 0.05–0.3 of full scale, so without a floor a quiet room would be
/// amplified into a wall of noise, and without auto-gain at all the bars would
/// barely leave the baseline.
const double _kReferenceFloor = 0.07;

/// How fast the loudness reference falls back toward the floor (seconds). Long
/// enough that a shout does not flatten the following sentence, short enough
/// that the scope re-sensitises within a breath.
const double _kReferenceTau = 1.1;

/// Bar envelope rates, per second. Fast attack keeps consonants crisp; a much
/// slower release is what makes the dial read as "amped" instead of flickery.
const double _kAttack = 38.0;
const double _kRelease = 7.5;

/// Below 1: lifts quiet detail toward the rim (loudness curve).
const double _kCurve = 0.6;

/// Hiss the slice envelope has to clear before it moves a bar at all.
const double _kNoiseFloor = 0.004;

/// A stalled stream (capture stopped, transport dropped) must not leave the
/// ring frozen mid-shout: with no frame for this long the envelope target
/// starts falling away on its own.
const double _kStallGrace = 0.12;
const double _kStallTau = 0.25;

/// Radians per second for the slow ring drift and the radar sweep.
const double _kRingDrift = 0.10;
const double _kSweepSpeed = 1.5;

/// Live audio dial: bars radiate from a glowing hub out toward the rim, with a
/// radar sweep washing over them and a halo that swells with the channel level.
///
/// The ring is mirrored about the vertical axis — each half carries the whole
/// frame — so the dial stays symmetric no matter what the waveform does.
///
/// Bars are auto-gained against the loudest thing heard in the last second or
/// so, then shaped by a loudness curve, so ordinary speech swings the full
/// radius instead of twitching at the hub.
class AudioVisualizer extends StatefulWidget {
  final List<double> samples;
  final double rms;
  final int barCount;
  final Color? color;

  const AudioVisualizer({
    super.key,
    required this.samples,
    required this.rms,
    this.barCount = 32,
    this.color,
  });

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  /// Painter-visible state, mutated in place on every vsync tick. Kept in one
  /// object so the painter can be rebuilt cheaply — and the cached shaders
  /// survive — while the envelope keeps advancing.
  late _ScopeData _data;

  /// Per-bar envelope asked for by the most recent audio frame (0..1, pre-gain).
  late List<double> _targets;

  /// Rolling loudness reference for the auto-gain.
  double _reference = _kReferenceFloor;

  /// Seconds since the last frame arrived, for the stall fallback.
  double _sinceFrame = 0;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _data = _ScopeData(widget.barCount);
    _targets = List<double>.filled(widget.barCount, 0);
    _ingest(widget.samples);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.barCount != widget.barCount) {
      // Resized in place: the painter keeps pointing at the same data object,
      // so nothing has to be torn down mid-flight.
      _data.resize(widget.barCount);
      _targets = List<double>.filled(widget.barCount, 0);
    }
    // The stream hands us a fresh list per frame; a parent rebuild for an
    // unrelated reason (colour, layout) reuses the same one and must not be
    // re-ingested as if it were new audio.
    if (!identical(oldWidget.samples, widget.samples)) _ingest(widget.samples);
  }

  /// Fold one audio frame down to [barCount] envelope values.
  ///
  /// Every sample is inspected: each bar takes the peak of its slice blended
  /// with the slice's RMS. Point-sampling one value per bar (the obvious
  /// approach) lands on arbitrary points of the waveform — including near
  /// zero-crossings — which is why the bars used to read as noise rather than
  /// as a level.
  void _ingest(List<double> samples) {
    final len = samples.length;
    if (len == 0) return;

    _sinceFrame = 0;
    final bars = _targets.length;
    var framePeak = 0.0;

    for (var i = 0; i < bars; i++) {
      final start = i * len ~/ bars;
      final end = max(start + 1, (i + 1) * len ~/ bars);

      var peak = 0.0;
      var sumSq = 0.0;
      for (var j = start; j < end; j++) {
        final v = samples[j].abs();
        if (v > peak) peak = v;
        sumSq += v * v;
      }
      if (peak > framePeak) framePeak = peak;

      // Peak keeps transients sharp, RMS gives the bar body so one stray
      // sample cannot slam it to full scale on its own.
      final env = peak * 0.65 + sqrt(sumSq / (end - start)) * 0.35;
      _targets[i] = max(0.0, env - _kNoiseFloor);
    }

    // The reference tracks loud material instantly and lets go slowly (see
    // _onTick), so the dial is calibrated to whoever is talking right now.
    if (framePeak > _reference) _reference = framePeak;
  }

  void _onTick(Duration elapsed) {
    // Clamped so a dropped frame or a resume from background cannot make the
    // envelope jump; dt only ever covers plausible frame times.
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 1 / 24);
    _lastTick = elapsed;
    if (dt <= 0) return;

    _reference =
        _kReferenceFloor +
        (_reference - _kReferenceFloor) * exp(-dt / _kReferenceTau);

    // Frames stopped arriving: let the last envelope fall away rather than
    // holding the ring at whatever it was showing when the stream died.
    _sinceFrame += dt;
    if (_sinceFrame > _kStallGrace) {
      final fade = exp(-dt / _kStallTau);
      for (var i = 0; i < _targets.length; i++) {
        _targets[i] *= fade;
      }
    }

    final scale = 1 / _reference;
    final levels = _data.levels;
    var sum = 0.0;

    for (var i = 0; i < levels.length; i++) {
      final normalised = (_targets[i] * scale).clamp(0.0, 1.0);
      final target = pow(normalised, _kCurve).toDouble();
      final rate = target > levels[i] ? _kAttack : _kRelease;
      levels[i] += (target - levels[i]) * (1 - exp(-rate * dt));
      sum += levels[i];
    }

    _data.energy = levels.isEmpty ? 0 : sum / levels.length;
    _data.drift = (_data.drift + dt * _kRingDrift) % (2 * pi);
    _data.sweep = (_data.sweep + dt * _kSweepSpeed) % (2 * pi);
    _data.repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    // The painter repaints off _data.repaint, which the ticker bumps once per
    // vsync — so the dial animates at 60fps without this widget (or the page
    // around it) ever rebuilding. The RepaintBoundary keeps those audio-rate
    // repaints off the surrounding layer.
    return RepaintBoundary(
      child: CustomPaint(
        painter: _VisualizerPainter(
          data: _data,
          color: widget.color ?? Theme.of(context).colorScheme.primary,
        ),
        size: Size.infinite,
      ),
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    _data.dispose();
    super.dispose();
  }
}

/// Mutable bag shared between the ticker and the painter, plus the shader cache.
class _ScopeData {
  /// Displayed bar heights, 0..1, chasing the audio envelope.
  List<double> levels;

  /// Mean of [levels] — drives the halo and hub brightness.
  double energy = 0;

  /// Slow rotation of the whole ring.
  double drift = 0;

  /// Angle of the radar sweep.
  double sweep = 0;

  final ValueNotifier<int> repaint = ValueNotifier<int>(0);

  _ScopeData(int barCount) : levels = List<double>.filled(barCount, 0);

  void resize(int barCount) => levels = List<double>.filled(barCount, 0);

  // Gradients are rebuilt only when the geometry or the status colour changes;
  // the sweep and the level are animated by rotating the canvas and by paint
  // colours, not by rebuilding shaders 60 times a second.
  Size? _cachedSize;
  Color? _cachedColor;
  ui.Shader? barShader;
  ui.Shader? sweepShader;
  ui.Shader? hubShader;

  void ensureShaders(Size size, Color color, double inner, double outer) {
    if (_cachedSize == size && _cachedColor == color) return;
    _cachedSize = size;
    _cachedColor = color;

    final center = Offset(size.width / 2, size.height / 2);
    final bounds = Rect.fromCircle(center: center, radius: outer);

    // Soft glow filling the hub, brightest dead centre.
    hubShader = RadialGradient(
      colors: [color.withValues(alpha: .22), color.withValues(alpha: 0)],
    ).createShader(Rect.fromCircle(center: center, radius: inner));

    // Bars fade toward the hub so the ring reads as light thrown outward.
    barShader = RadialGradient(
      colors: [
        color.withValues(alpha: .45),
        color.withValues(alpha: .95),
        color,
      ],
      stops: [inner / outer, (inner / outer + 1) / 2, 1],
    ).createShader(bounds);

    // One revolution of tint, transparent through the tail: a radar wash.
    sweepShader = SweepGradient(
      colors: [
        color.withValues(alpha: 0),
        color.withValues(alpha: 0),
        color.withValues(alpha: .13),
        color.withValues(alpha: 0),
      ],
      stops: const [0, .55, .95, 1],
    ).createShader(bounds);
  }

  void dispose() => repaint.dispose();
}

class _VisualizerPainter extends CustomPainter {
  final _ScopeData data;
  final Color color;

  _VisualizerPainter({required this.data, required this.color})
    : super(repaint: data.repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final levels = data.levels;
    if (levels.isEmpty || size.shortestSide <= 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final count = levels.length;
    // Hub / rim / how far a full-scale bar reaches. The band is inset by half
    // a stroke at each end so round caps land exactly on hub and rim instead
    // of spilling into the tick ring.
    final hub = radius * 0.48;
    final rim = radius * 0.97;
    final stroke = min(7.0, pi * (hub + rim) / count * 0.5);
    final span = rim - hub - stroke;
    final energy = data.energy;

    data.ensureShaders(size, color, hub, rim);

    // Single ambient halo for the whole dial — one GPU pass, sized by the
    // channel level, instead of a blur per bar (which was very expensive).
    if (energy > 0.02) {
      canvas.drawCircle(
        center,
        hub + span * energy * 0.9,
        Paint()
          ..color = color.withValues(alpha: (energy * 0.30).clamp(0.0, 0.22))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
      );
    }

    // Rim and the quarter ticks: the dial's fixed framing.
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.14 + energy * 0.25);
    canvas.drawCircle(center, rim, rimPaint);

    final tickPaint = Paint()
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.25 + energy * 0.35);
    for (var i = 0; i < 12; i++) {
      final a = i * pi / 6;
      final d = Offset(cos(a), sin(a));
      final long = i % 3 == 0;
      canvas.drawLine(
        center + d * (rim + 3),
        center + d * (rim + (long ? 9 : 5)),
        tickPaint,
      );
    }

    // Radar sweep under the bars, animated by rotating the canvas so its
    // gradient shader can stay cached.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(data.sweep);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawCircle(
      center,
      (hub + rim) / 2,
      Paint()
        ..shader = data.sweepShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = span,
    );
    canvas.restore();

    // Hub: a soft disc, ringed by a hairline that brightens with the level.
    canvas.drawCircle(center, hub, Paint()..shader = data.hubShader);
    canvas.drawCircle(
      center,
      hub,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.30 + energy * 0.45),
    );

    // Bars. Capsules with a small floor length plus a travelling shimmer, so a
    // silent channel keeps a live dotted ring instead of collapsing to nothing.
    // The stroke is sized off the middle of the band, not the hub, so they read
    // as bars rather than hairlines once the ring gets busy.
    final barPaint = Paint()
      ..shader = data.barShader
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;

    const floor = 1.0;
    final start = hub + stroke / 2;
    final drift = data.drift;

    for (var i = 0; i < count; i++) {
      // Mirror about the vertical axis: each half of the ring carries the whole
      // frame, so the dial is symmetric without halving the detail.
      final folded = i <= count ~/ 2 ? i : count - i;
      final level = levels[min(folded * 2, count - 1)];

      final shimmer = 1.8 * (0.5 + 0.5 * sin(drift * 6 - i * 0.4));
      final length = floor + shimmer * (1 - level) + level * span;

      final a = -pi / 2 + drift + i * 2 * pi / count;
      final d = Offset(cos(a), sin(a));
      canvas.drawLine(
        center + d * start,
        center + d * (start + length),
        barPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) =>
      oldDelegate.color != color || !identical(oldDelegate.data, data);
}
