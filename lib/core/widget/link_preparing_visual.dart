import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import '../theme/theme_service.dart';
import 'qr_widgets.dart';

/// Which link this phone is bringing up while the code is on its way.
enum LinkPreparingKind {
  /// This phone is becoming a Wi-Fi hotspot the other phone will join.
  hotspot,

  /// This phone is waking Bluetooth up and starting to advertise.
  bluetooth,

  /// No radio to raise — only the code itself is being written (signing the
  /// invite, for example).
  code,
}

/// The wait before a QR code exists, drawn as the thing that is happening.
///
/// Replaces a bare spinner over "Getting your phone ready…". That spinner said
/// *wait*; it did not say what for, and the wait it covered — a hotspot or a
/// Bluetooth beacon coming up — is the one moment in the flow where the phone
/// is doing something genuinely physical.
///
/// So the visual tells it: in the middle of an empty code tile this phone sits
/// as a beacon, sending out pulses (solid Wi-Fi rings for a hotspot, dotted
/// short-range pulses for Bluetooth). Each pulse that crosses the tile *writes*
/// a few more modules of a QR code where it passes — the three finder eyes
/// first, the way a real code is anchored, then the data filling in from the
/// centre out. The code is never finished while the link is still coming up;
/// it fills towards most-of-the-way and keeps shimmering under each pulse.
///
/// When [ready] arrives the last modules land in one sweep, the tile turns
/// from the page's card to the QR's white and the modules from amber to ink,
/// and only then does the real code dissolve in over it. The box is exactly
/// [GlowingQrCard]'s footprint for the same [qrSize] — same tile, same corner
/// brackets, the beacon where the brand mark sits — so nothing moves when the
/// one replaces the other. If [ready] goes away again (the link is being
/// re-raised), the same morph plays backwards.
///
/// ## Cost
///
/// One [CustomPainter] in one [RepaintBoundary]. The ~800 modules are a
/// single `drawVertices` call with per-vertex colours; the rings are a
/// handful of strokes. No blur, no `ClipPath`, no per-module widgets. The
/// clock stops once the real code is fully shown, and under reduced motion
/// nothing loops: a calm, mostly written frame is drawn and the hand-over is a
/// short crossfade.
class LinkPreparingVisual extends StatefulWidget {
  const LinkPreparingVisual({
    required this.kind,
    this.qrSize = 250,
    this.ready,
    super.key,
  });

  final LinkPreparingKind kind;

  /// The `size` of the [GlowingQrCard] this resolves into.
  final double qrSize;

  /// The real code, once there is one — normally a [GlowingQrCard] built with
  /// the same [qrSize]. Null while the link is still coming up.
  final Widget? ready;

  /// The square this widget occupies for [qrSize]: [GlowingQrCard]'s own.
  static double extentFor(double qrSize) => qrSize + 28 + 26;

  @override
  State<LinkPreparingVisual> createState() => _LinkPreparingVisualState();
}

class _LinkPreparingVisualState extends State<LinkPreparingVisual>
    with TickerProviderStateMixin {
  /// Seconds since the beacon started, as an animation the painter listens to.
  /// Long enough that nobody waits it out; it stops as soon as it is not
  /// needed.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(minutes: 10),
  );

  /// 0 = still preparing, 1 = the real code fully shown.
  late final AnimationController _resolve = AnimationController(
    vsync: this,
    duration: _resolveDuration,
    value: widget.ready == null ? 0 : 1,
  );

  static const _resolveDuration = Duration(milliseconds: 760);

  late _ModuleField _field = _ModuleField(widget.kind);
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _resolve.addStatusListener(_onResolveStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _resolve.duration = _reduced ? AppMotion.card : _resolveDuration;
    _syncClock();
  }

  @override
  void didUpdateWidget(LinkPreparingVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind) _field = _ModuleField(widget.kind);
    final wasReady = oldWidget.ready != null;
    final isReady = widget.ready != null;
    if (isReady && !wasReady) {
      _resolve.forward();
    } else if (!isReady && wasReady) {
      // Back to preparing: the pulses start over rather than resuming a code
      // that was, a moment ago, complete.
      _clock.value = 0;
      _resolve.reverse();
    }
    _syncClock();
  }

  void _onResolveStatus(AnimationStatus status) => _syncClock();

  /// The clock runs while anything driven by it is visible.
  void _syncClock() {
    final settled = widget.ready != null && _resolve.isCompleted;
    if (_reduced || settled) {
      if (_clock.isAnimating) _clock.stop();
    } else if (!_clock.isAnimating) {
      _clock.forward();
    }
  }

  @override
  void dispose() {
    _resolve.removeStatusListener(_onResolveStatus);
    _clock.dispose();
    _resolve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extent = LinkPreparingVisual.extentFor(widget.qrSize);
    final ready = widget.ready;
    return SizedBox.square(
      dimension: extent,
      // Through the theme listenable, not captured once: this subtree can
      // outlive a light/dark switch and the painter holds plain colours.
      child: ValueListenableBuilder<AppThemeMode>(
        valueListenable: ThemeService.mode,
        builder: (context, _, _) => AnimatedBuilder(
          animation: _resolve,
          builder: (context, _) {
            final r = _resolve.value;
            final childIn = _reduced ? r : _span(r, 0.56, 1);
            final showPainter = r < 1 || ready == null;
            return Stack(
              alignment: Alignment.center,
              children: [
                if (showPainter)
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _BeaconPainter(
                          clock: _clock,
                          resolve: _resolve,
                          field: _field,
                          qrSize: widget.qrSize,
                          reduced: _reduced,
                          tile: AppColors.card,
                          rim: AppColors.amber,
                          // What the real code's modules are drawn in.
                          ink: Colors.black,
                          module: AppColors.amber,
                        ),
                      ),
                    ),
                  ),
                if (showPainter)
                  _Emblem(
                    kind: widget.kind,
                    size: widget.qrSize * 0.24,
                    clock: _clock,
                    // Goes white with the tile — the brand mark's quiet ring
                    // is white — then gives way to the mark itself.
                    whiten: _whiten(r, _reduced),
                    fade: _reduced ? 1 - r : 1 - _span(r, 0.5, 0.9),
                  ),
                if (ready != null && childIn > 0)
                  Opacity(
                    opacity: childIn,
                    child: Transform.scale(
                      scale: _reduced ? 1 : 0.985 + 0.015 * childIn,
                      // A fresh code (new credentials) replacing the one on
                      // screen dissolves into it rather than cutting.
                      child: AnimatedSwitcher(
                        duration: AppMotion.card,
                        switchInCurve: AppMotion.easeOut,
                        switchOutCurve: AppMotion.leaving,
                        child: ready,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The two lines under the visual: what is happening, then over what.
class LinkPreparingCaption extends StatelessWidget {
  const LinkPreparingCaption({required this.kind, super.key});

  final LinkPreparingKind kind;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final detail = switch (kind) {
      LinkPreparingKind.hotspot => s.linkprep_hotspot_detail,
      LinkPreparingKind.bluetooth => s.linkprep_bluetooth_detail,
      LinkPreparingKind.code => s.linkprep_code_detail,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          s.reconnect_preparing,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// The beacon in the middle: this phone, in the spot the brand mark takes
/// once the code is real.
class _Emblem extends StatelessWidget {
  const _Emblem({
    required this.kind,
    required this.size,
    required this.clock,
    required this.whiten,
    required this.fade,
  });

  final LinkPreparingKind kind;
  final double size;
  final Animation<double> clock;
  final double whiten;
  final double fade;

  @override
  Widget build(BuildContext context) {
    if (fade <= 0) return const SizedBox.shrink();
    final icon = switch (kind) {
      LinkPreparingKind.hotspot => Icons.wifi_tethering_rounded,
      LinkPreparingKind.bluetooth => Icons.bluetooth_rounded,
      LinkPreparingKind.code => Icons.smartphone_rounded,
    };
    final period = _ModuleField.periodFor(kind);
    return Opacity(
      opacity: fade,
      child: AnimatedBuilder(
        animation: clock,
        // The box and glyph are built once; only the transform moves.
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Color.lerp(AppColors.card, Colors.white, whiten),
            borderRadius: BorderRadius.circular(size * 0.3),
            border: Border.all(
              color: AppColors.amber.withValues(alpha: 1 - whiten),
              width: 1.6,
            ),
          ),
          child: Icon(
            icon,
            size: size * 0.52,
            color: AppColors.amber.withValues(alpha: 1 - whiten),
          ),
        ),
        builder: (context, child) {
          final t = _seconds(clock);
          // A small kick on each pulse it sends, settling before the next.
          final phase = (t % period) / period;
          final kick = math.exp(-phase * 7) * (1 - math.exp(-t * 3));
          return Transform.scale(scale: 1 + 0.07 * kick, child: child);
        },
      ),
    );
  }
}

double _seconds(Animation<double> clock) => clock.value * 600;

/// How far the tile has gone from the page's card to the code's white, for a
/// [LinkPreparingVisual] resolve value [r].
double _whiten(double r, bool reduced) =>
    reduced ? r : AppMotion.easeOut.transform(_span(r, 0.2, 0.62));

/// Normalised progress of one beat: 0 before [start], 1 after [end].
double _span(double t, double start, double end) =>
    ((t - start) / (end - start)).clamp(0.0, 1.0);

/// A believable QR layout and, for every module, the moment a pulse writes it.
///
/// Built once per kind. The pattern is fixed (seeded) so the same code
/// assembles itself every time — it is a picture of a code, not data — and
/// all the timing that depends only on a module's place is precomputed here,
/// leaving the painter a lookup and a few multiplies per module per frame.
class _ModuleField {
  _ModuleField(this.kind) {
    final random = math.Random(1403);
    final half = (n - 1) / 2;
    final maxD = math.sqrt(2) * half;
    final hole = (n * 0.24 / 2 + 0.9);
    final finderOrder = <int>[];
    final cells = <int>[];
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final dx = x - half;
        final dy = y - half;
        // The beacon's square: the brand mark's hole in the real code.
        if (dx.abs() < hole && dy.abs() < hole) continue;
        final finder = _finderCell(x, y);
        final timing = !finder.inZone && (x == 6 || y == 6);
        final bool dark;
        if (finder.inZone) {
          dark = finder.dark;
        } else if (timing) {
          dark = (x + y).isEven;
        } else {
          dark = random.nextDouble() < 0.47;
        }
        // Drawn before the skip so the pattern does not shift with it.
        final h = random.nextDouble();
        // A light module is just tile: only dark ones are drawn.
        if (!dark) continue;
        cells.add(y * n + x);
        if (finder.inZone) finderOrder.add(cells.length - 1);
        _distance.add(math.sqrt(dx * dx + dy * dy) / maxD);
        _threshold.add(h);
        _structural.add(finder.inZone || timing);
      }
    }
    count = cells.length;
    xs = Float32List(count);
    ys = Float32List(count);
    written = Float32List(count);
    for (var i = 0; i < count; i++) {
      xs[i] = (cells[i] % n).toDouble();
      ys[i] = (cells[i] ~/ n).toDouble();
      written[i] = _writtenAt(i);
    }
    // The finder eyes trace themselves first, one eye after another.
    for (var j = 0; j < finderOrder.length; j++) {
      written[finderOrder[j]] = 0.15 + 0.75 * j / finderOrder.length;
    }
  }

  final LinkPreparingKind kind;

  /// Modules per side: a version-3 code, dense enough to read as a QR, sparse
  /// enough that each module is a visible tile at phone sizes.
  static const n = 29;

  /// Seconds between pulses. Bluetooth is a quicker, shorter-range chirp.
  static double periodFor(LinkPreparingKind kind) => switch (kind) {
    LinkPreparingKind.bluetooth => 1.1,
    _ => 1.6,
  };

  double get period => periodFor(kind);

  /// Seconds a pulse takes from the beacon to the tile's corners.
  static const travel = 1.25;

  /// How much of the code can be written before the link is actually up.
  static const ceiling = 0.86;

  /// Time constant of the fill: most of it lands in the first few seconds,
  /// then it creeps — a long wait never looks finished, never looks stuck.
  static const fillTau = 3.4;

  late final int count;
  late final Float32List xs;
  late final Float32List ys;

  /// Seconds after the start when each module is written while preparing;
  /// infinity for those that wait for the link.
  late final Float32List written;
  final _distance = <double>[];
  final _threshold = <double>[];
  final _structural = <bool>[];

  double distance(int i) => _distance[i];

  double _writtenAt(int i) {
    final d = _distance[i];
    final h = _structural[i] ? _threshold[i] * 0.25 : _threshold[i];
    final arrive = d * travel;
    if (h >= ceiling) return double.infinity;
    // When the fill first covers this module's threshold…
    final due = -fillTau * math.log(1 - h / ceiling);
    // …it lands with the first pulse to reach it after that.
    final k = math.max(0, ((due - arrive) / period).ceil());
    return k * period + arrive + 0.35;
  }

  static ({bool inZone, bool dark}) _finderCell(int x, int y) {
    for (final (ox, oy) in const [(0, 0), (n - 7, 0), (0, n - 7)]) {
      final fx = x - ox;
      final fy = y - oy;
      if (fx >= -1 && fx <= 7 && fy >= -1 && fy <= 7) {
        if (fx < 0 || fx > 6 || fy < 0 || fy > 6) {
          return (inZone: true, dark: false);
        }
        final ring = fx == 0 || fx == 6 || fy == 0 || fy == 6;
        final core = fx >= 2 && fx <= 4 && fy >= 2 && fy <= 4;
        return (inZone: true, dark: ring || core);
      }
    }
    return (inZone: false, dark: false);
  }
}

class _BeaconPainter extends CustomPainter {
  _BeaconPainter({
    required this.clock,
    required this.resolve,
    required this.field,
    required this.qrSize,
    required this.reduced,
    required this.tile,
    required this.rim,
    required this.ink,
    required this.module,
  }) : super(repaint: Listenable.merge([clock, resolve]));

  final Animation<double> clock;
  final Animation<double> resolve;
  final _ModuleField field;
  final double qrSize;
  final bool reduced;
  final Color tile;
  final Color rim;
  final Color ink;
  final Color module;

  /// Preallocated per painter: rewritten in place every frame.
  late final Float32List _positions = Float32List(field.count * 12);
  late final Int32List _colors = Int32List(field.count * 6);

  @override
  void paint(Canvas canvas, Size size) {
    // Under reduced motion the frame is a still: most of the code written,
    // no pulse in flight.
    final t = reduced ? 9.0 : _seconds(clock);
    final r = resolve.value;
    final center = size.center(Offset.zero);
    final tileSide = qrSize + 28;
    final tileRect = Rect.fromCenter(
      center: center,
      width: tileSide,
      height: tileSide,
    );
    final tileRRect = RRect.fromRectAndRadius(
      tileRect,
      const Radius.circular(18),
    );

    // Beats of the hand-over, as fractions of [resolve].
    final sweep = reduced ? 1.0 : _span(r, 0, 0.42);
    final whiten = _whiten(r, reduced);
    final ringsOut = reduced ? 1.0 : 1 - _span(r, 0, 0.3);

    // Corner brackets: GlowingQrCard's own, breathing a hair while waiting.
    final breath = reduced
        ? 0.0
        : math.sin(t * math.pi * 2 / (field.period * 2)) * (1 - whiten);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1 + 0.012 * breath);
    canvas.translate(-center.dx, -center.dy);
    CornerBracketsPainter(
      color: rim.withAlpha((120 + 70 * whiten).round()),
    ).paint(canvas, size);
    canvas.restore();

    // The tile, from page card to the QR's paper.
    final tileColor = Color.lerp(tile, Colors.white, whiten)!;
    canvas.drawRRect(tileRRect, Paint()..color = tileColor);
    canvas.drawRRect(
      tileRRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = rim.withValues(alpha: 0.28 * (1 - whiten)),
    );

    canvas.save();
    canvas.clipRRect(tileRRect);

    // Pulses leaving the beacon.
    final maxR = tileSide / 2 * math.sqrt2;
    final half = qrSize * 0.12;
    if (ringsOut > 0) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var k = 0; k < 3; k++) {
        final age = (t % field.period) + k * field.period;
        final p = age / _ModuleField.travel;
        if (p > 1 || age > t) continue;
        final radius = half + (maxR - half) * p;
        final alpha = math.pow(1 - p, 1.4) * 0.8 * ringsOut;
        ring
          ..color = rim.withValues(alpha: alpha.toDouble())
          ..strokeWidth = 2.4 - 1.2 * p;
        if (field.kind == LinkPreparingKind.bluetooth) {
          ring.strokeWidth = 3.4 - 1.4 * p;
          _dottedCircle(canvas, center, radius, ring);
        } else {
          canvas.drawCircle(center, radius, ring);
        }
      }
    }

    // The code, one vertex batch.
    final m = qrSize / _ModuleField.n;
    final origin = center - Offset(qrSize / 2, qrSize / 2);
    final pos = _positions;
    final col = _colors;
    for (var i = 0; i < field.count; i++) {
      var written = field.written[i];
      // The hand-over writes whatever is left, from the beacon outwards.
      final sweptAt = field.distance(i);
      final swept = sweep >= sweptAt && sweep > 0;
      double age;
      if (t >= written) {
        age = t - written;
      } else if (swept) {
        written = 0;
        age = (sweep - sweptAt) * 2.2;
      } else {
        age = -1;
      }
      double scale;
      double alpha;
      if (age < 0) {
        scale = 0;
        alpha = 0;
      } else {
        // Lands a touch oversized and settles — the only overshoot here.
        final land = _span(age, 0, 0.32);
        scale = reduced ? 1 : Curves.easeOutBack.transform(land);
        // Arrives bright, settles to a steady glow.
        final flash = math.exp(-age * 3.2);
        // Every later pulse brushes it again on the way past.
        final since = t - field.distance(i) * _ModuleField.travel;
        final brush = reduced || since < 0
            ? 0.0
            : math.exp(-(since % field.period) * 5) * 0.28;
        alpha = (0.5 + 0.5 * flash + brush).clamp(0.0, 1.0) * land;
      }
      // On white the modules become ink, solid.
      alpha = alpha + (1 - alpha) * whiten * (scale > 0 ? 1 : 0);
      if (whiten > 0 && scale > 0) scale = scale + (1 - scale) * whiten;
      final color = Color.lerp(module, ink, whiten)!.withValues(
        alpha: alpha.clamp(0.0, 1.0),
      );
      final s = m * (0.84 + 0.16 * whiten) * scale / 2;
      final cx = origin.dx + (field.xs[i] + 0.5) * m;
      final cy = origin.dy + (field.ys[i] + 0.5) * m;
      final o = i * 12;
      // Two triangles per module.
      pos[o] = cx - s;
      pos[o + 1] = cy - s;
      pos[o + 2] = cx + s;
      pos[o + 3] = cy - s;
      pos[o + 4] = cx + s;
      pos[o + 5] = cy + s;
      pos[o + 6] = cx - s;
      pos[o + 7] = cy - s;
      pos[o + 8] = cx + s;
      pos[o + 9] = cy + s;
      pos[o + 10] = cx - s;
      pos[o + 11] = cy + s;
      final argb = color.toARGB32();
      final c = i * 6;
      col[c] = argb;
      col[c + 1] = argb;
      col[c + 2] = argb;
      col[c + 3] = argb;
      col[c + 4] = argb;
      col[c + 5] = argb;
    }
    canvas.drawVertices(
      ui.Vertices.raw(VertexMode.triangles, pos, colors: col),
      BlendMode.dst,
      Paint(),
    );
    canvas.restore();
  }

  static void _dottedCircle(Canvas canvas, Offset c, double radius, Paint p) {
    final dots = (radius * 2 * math.pi / 9).floor().clamp(12, 120);
    final points = Float32List(dots * 2);
    for (var i = 0; i < dots; i++) {
      final a = i / dots * math.pi * 2;
      points[i * 2] = c.dx + math.cos(a) * radius;
      points[i * 2 + 1] = c.dy + math.sin(a) * radius;
    }
    canvas.drawRawPoints(ui.PointMode.points, points, p);
  }

  @override
  bool shouldRepaint(_BeaconPainter old) =>
      old.field != field ||
      old.qrSize != qrSize ||
      old.reduced != reduced ||
      old.tile != tile ||
      old.rim != rim ||
      old.module != module;
}
