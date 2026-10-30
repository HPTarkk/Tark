import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import '../utils/extensions.dart';
import 'recovery_banner.dart';
import 'recovery_check.dart';

/// The always-available "something's not working" sheet.
///
/// Its whole job is to guarantee there is never a dead end. Banners cover the
/// failures we predicted; this covers the ones we didn't, by showing the live
/// state of each thing the session depends on and putting the fix next to
/// whatever is red. Even when every row is green it still answers a real
/// question — "is it me?" — which is the state people otherwise sit in.
///
/// It is dressed as an instrument taking a reading, because that is what it
/// is. On open the rows land as blanks, a scan line travels down through them
/// and each one resolves — its finding rises into place, its mark springs in —
/// the moment the line passes. The dial in the header is the same reading seen
/// from above: one segment per row, each drawing in step with the line and
/// taking that row's colour, until the verdict lands in the middle. When every
/// check passes, the segments close into one unbroken ring.
///
/// That sequence is load-bearing rather than decorative — a list of green
/// ticks that is simply *present* the instant the sheet opens looks like a
/// static picture of reassurance, and people do not believe it. Watching it
/// resolve is what makes the verdict read as a result.
///
/// Fed by a stream so the rows correct themselves while the sheet is open:
/// the user grants the mic permission from the row's own button, comes back,
/// and watches it turn green — the mark springs, the dial segment re-tints and
/// the verdict redraws — without having to close and reopen anything.
Future<void> showRecoverySheet(
  BuildContext context, {
  required List<RecoveryCheck> initial,
  required Stream<List<RecoveryCheck>> checks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    routeSettings: const RouteSettings(name: 'RecoverySheet'),
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => _RecoverySheet(initial: initial, checks: checks),
  );
}

// ── Timeline ─────────────────────────────────────────────────────────────────

/// Where each beat of the opening reading sits on the one shared controller.
///
/// Pure arithmetic over the number of rows in the *original* reading, so the
/// dial, the scan line and the rows all agree on when row `i` is read without
/// talking to each other. Rows the stream adds later are past the end of the
/// reading; they borrow the last row's slot, which has finished by the time
/// they can exist.
class _Reading {
  _Reading(int count) : count = math.max(1, count);

  final int count;

  static const double _scanFrom = 0.14;
  static const double _scanTo = 0.80;

  int _slot(int i) => i.clamp(0, count - 1);

  /// The row rises into place, blank, ahead of the line reaching it.
  Interval entrance(int i) {
    final start = math.min(_slot(i) * 0.035, 0.3);
    return Interval(start, start + 0.2, curve: AppMotion.easeOut);
  }

  double _scanStart(int i) =>
      _scanFrom + (_scanTo - _scanFrom) * _slot(i) / count;
  double _scanEnd(int i) =>
      _scanFrom + (_scanTo - _scanFrom) * (_slot(i) + 1) / count;

  /// The line crossing the row, top to bottom. Linear: the line is a reading
  /// head, and a head that eased in and out per row would stutter at every
  /// gap between them.
  Interval scan(int i) => Interval(_scanStart(i), _scanEnd(i));

  /// The finding arriving, just past the row's middle — after the line has
  /// visibly looked at it.
  Interval resolve(int i, {Curve curve = AppMotion.easeOut}) {
    final start = _scanStart(i) + (_scanEnd(i) - _scanStart(i)) * 0.55;
    return Interval(start, math.min(1, start + 0.14), curve: curve);
  }

  /// A broken row's flare: longer than [resolve], so the glow is still
  /// settling after the row itself has.
  Interval flare(int i) {
    final start = resolve(i).begin;
    return Interval(start, math.min(1, start + 0.36), curve: Curves.easeOut);
  }

  static const Interval verdict = Interval(0.8, 0.98, curve: AppMotion.easeOut);
  static const Interval radarOut = Interval(0.76, 0.9, curve: Curves.easeOut);
  static const Interval mark = Interval(0.84, 1, curve: AppMotion.easeOut);
  static const Interval close = Interval(0.82, 1, curve: AppMotion.easeInOut);
  static const Interval halo = Interval(0.86, 1, curve: Curves.easeOut);

  /// Long enough that every row gets a visible pass of the line, short enough
  /// that a six-row reading never feels like the app is stalling.
  Duration get duration =>
      Duration(milliseconds: (520 + 150 * count).clamp(900, 1700));
}

// ── Sheet ────────────────────────────────────────────────────────────────────

class _RecoverySheet extends StatefulWidget {
  const _RecoverySheet({required this.initial, required this.checks});

  final List<RecoveryCheck> initial;
  final Stream<List<RecoveryCheck>> checks;

  @override
  State<_RecoverySheet> createState() => _RecoverySheetState();
}

class _RecoverySheetState extends State<_RecoverySheet>
    with TickerProviderStateMixin {
  late final _Reading _reading = _Reading(widget.initial.length);

  /// Runs once on open: the rows land, the line falls, the verdict lands.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: _reading.duration,
  );

  /// Carries the dial's segments from the colours they had to the ones the
  /// stream just reported, so a row turning green while the sheet is open
  /// re-tints its segment instead of snapping it.
  late final AnimationController _retint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: 1,
  );

  /// Redraws the verdict mark when the verdict itself changes while open.
  late final AnimationController _remark = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: 1,
  );

  late List<RecoveryCheck> _rows = widget.initial;
  late List<Color> _tintFrom = _tints(widget.initial);
  late List<Color> _tintTo = _tintFrom;

  /// Whether the last verdict change went from all-good to not, so the dial
  /// can open its closed ring back up rather than jumping.
  bool _openedFromGood = false;

  StreamSubscription<List<RecoveryCheck>>? _subscription;

  /// Which status the verdict last settled on, so a change while the sheet is
  /// open can buzz rather than silently redrawing.
  bool? _lastAllGood;

  @override
  void initState() {
    super.initState();
    _lastAllGood = _allGood(_rows);
    _subscription = widget.checks.listen(_onRows);
    _sweep.forward();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _sweep.dispose();
    _retint.dispose();
    _remark.dispose();
    super.dispose();
  }

  static bool _allGood(List<RecoveryCheck> rows) =>
      rows.every((check) => check.isHealthy);

  static List<Color> _tints(List<RecoveryCheck> rows) => rows.isEmpty
      ? [AppColors.green]
      : [for (final check in rows) RecoveryBanner.accentFor(check.status)];

  void _onRows(List<RecoveryCheck> rows) {
    if (!mounted) return;
    final next = _tints(rows);
    setState(() {
      if (next.length == _tintTo.length) {
        // Start from wherever the segments are this frame, so an update that
        // lands mid-retint carries on instead of jumping back.
        final t = _retint.value;
        _tintFrom = [
          for (var i = 0; i < next.length; i++)
            Color.lerp(_tintFrom[i], _tintTo[i], t)!,
        ];
      } else {
        _tintFrom = next;
      }
      _tintTo = next;
      _rows = rows;
    });
    _retint.forward(from: 0);
    _onVerdict(_allGood(rows));
  }

  void _onVerdict(bool allGood) {
    if (_lastAllGood == allGood) return;
    _openedFromGood = _lastAllGood ?? false;
    _lastAllGood = allGood;
    _remark.forward(from: 0);
    // Never for the initial state — a haptic on open would be the sheet
    // congratulating itself. A change after that is news, and worth feeling.
    if (allGood) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final reduced = AppMotion.reduced(context);
    final rows = _rows;
    final allGood = _allGood(rows);
    final broken = [
      for (var i = 0; i < rows.length; i++)
        if (!rows[i].isHealthy) i,
    ];
    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          // Uniform on purpose: a rounded box can only be stroked with one
          // colour, and a per-side border here silently fails to paint at all.
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.22)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _Verdict(
                sweep: _sweep,
                retint: _retint,
                remark: _remark,
                reading: _reading,
                tintFrom: _tintFrom,
                tintTo: _tintTo,
                allGood: allGood,
                openedFromGood: _openedFromGood,
                broken: broken,
                total: rows.length,
                title: s.help_title,
                detail: allGood ? s.help_all_good : s.help_found_problems,
                reduced: reduced,
              ),
            ),
            const SizedBox(height: 18),
            Flexible(
              child: _CheckList(
                rows: rows,
                sweep: _sweep,
                reading: _reading,
                reduced: reduced,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: AppColors.textSecondary.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );
}

// ── Verdict ──────────────────────────────────────────────────────────────────

/// The reading seen from above: a segmented dial that fills row by row, then
/// holds the answer.
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.sweep,
    required this.retint,
    required this.remark,
    required this.reading,
    required this.tintFrom,
    required this.tintTo,
    required this.allGood,
    required this.openedFromGood,
    required this.broken,
    required this.total,
    required this.title,
    required this.detail,
    required this.reduced,
  });

  final Animation<double> sweep;
  final Animation<double> retint;
  final Animation<double> remark;
  final _Reading reading;
  final List<Color> tintFrom;
  final List<Color> tintTo;
  final bool allGood;
  final bool openedFromGood;

  /// Indices of the rows that are not healthy right now.
  final List<int> broken;
  final int total;
  final String title;
  final String detail;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final landing = CurvedAnimation(parent: sweep, curve: _Reading.verdict);
    Widget sentence = AnimatedSwitcher(
      duration: AppMotion.card,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      transitionBuilder: HandOver.transition(),
      layoutBuilder: _startAligned,
      // Swapped rather than re-styled, so a verdict that changes while the
      // sheet is open reads as new information arriving.
      child: Text(
        detail,
        key: ValueKey(allGood),
        style: TextStyle(
          color: allGood ? AppColors.green : AppColors.textSecondary,
          fontSize: 12.5,
          height: 1.45,
        ),
      ),
    );
    // The sentence is the verdict in words, so it waits for the reading like
    // the mark does. Its space is held from the first frame: a header that
    // grew as the answer arrived would shove every row down mid-scan.
    sentence = FadeTransition(
      opacity: landing,
      child: reduced
          ? sentence
          : SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(landing),
              child: sentence,
            ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RepaintBoundary(
          child: SizedBox(
            width: 58,
            height: 58,
            child: CustomPaint(
              painter: _DialPainter(
                sweep: sweep,
                retint: retint,
                remark: remark,
                reading: reading,
                tintFrom: tintFrom,
                tintTo: tintTo,
                allGood: allGood,
                openedFromGood: openedFromGood,
                reduced: reduced,
                scanning: AppColors.amber,
                track: AppColors.border,
              ),
            ),
          ),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              sentence,
              _Resize(
                reduced: reduced,
                child: broken.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: _CountPill(
                          sweep: sweep,
                          reading: reading,
                          broken: broken,
                          total: total,
                          reduced: reduced,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Eases a height change that arrives while the sheet is open — a fix
/// disappearing with its problem, the count pill leaving with the last one.
///
/// Under reduced motion the new height simply applies. `AnimatedSize` cannot
/// be given a zero duration instead: it re-dirties its own layout and throws.
class _Resize extends StatelessWidget {
  const _Resize({required this.reduced, required this.child});

  final bool reduced;
  final Widget child;

  @override
  Widget build(BuildContext context) => reduced
      ? child
      : AnimatedSize(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: child,
        );
}

Widget _startAligned(Widget? current, List<Widget> previous) => Stack(
  alignment: AlignmentDirectional.topStart,
  children: [...previous, ?current],
);

/// "2 / 5", counted up as the line finds each problem rather than announced
/// before it has looked.
class _CountPill extends StatelessWidget {
  const _CountPill({
    required this.sweep,
    required this.reading,
    required this.broken,
    required this.total,
    required this.reduced,
  });

  final Animation<double> sweep;
  final _Reading reading;
  final List<int> broken;
  final int total;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    // The pill arrives with the first problem the line finds. Its space is
    // already held (see the sentence above), so its arrival moves nothing.
    final first = reading.resolve(broken.first, curve: Curves.easeOutBack);
    final arrival = CurvedAnimation(parent: sweep, curve: first);
    final pill = AnimatedBuilder(
      animation: sweep,
      builder: (context, _) {
        final t = sweep.value;
        final found = broken
            .where((i) => reading.resolve(i).transform(t) >= 0.5)
            .length;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
          ),
          // Counts stay LTR in Persian: "2 / 5" reversed reads as a different
          // ratio.
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: AnimatedSwitcher(
              duration: AppMotion.chip,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: HandOver.transition(rise: 0.5, lift: 0.4),
              child: Text(
                '${math.max(found, 1)} / $total'.localized(context),
                key: ValueKey('${math.max(found, 1)}/$total'),
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        );
      },
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: sweep,
          curve: reading.resolve(broken.first),
        ),
        child: reduced
            ? pill
            : ScaleTransition(
                scale: Tween<double>(begin: 0.6, end: 1).animate(arrival),
                alignment: AlignmentDirectional.centerStart.resolve(
                  Directionality.of(context),
                ),
                child: pill,
              ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.sweep,
    required this.retint,
    required this.remark,
    required this.reading,
    required this.tintFrom,
    required this.tintTo,
    required this.allGood,
    required this.openedFromGood,
    required this.reduced,
    required this.scanning,
    required this.track,
  }) : super(repaint: Listenable.merge([sweep, retint, remark]));

  final Animation<double> sweep;
  final Animation<double> retint;
  final Animation<double> remark;
  final _Reading reading;
  final List<Color> tintFrom;
  final List<Color> tintTo;
  final bool allGood;
  final bool openedFromGood;
  final bool reduced;
  final Color scanning;
  final Color track;

  static const double _gap = 0.24;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 4;
    final t = sweep.value;
    final redraw = AppMotion.easeOut.transform(remark.value);
    final settled = allGood ? AppColors.green : AppColors.amber;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );

    // All good: the gaps between segments close into one ring. A verdict
    // that turns bad while open pries it back apart.
    final close = allGood
        ? math.min(_Reading.close.transform(t), redraw)
        : openedFromGood
        ? 1 - redraw
        : 0.0;

    // A single halo pushing out of the ring as a bad answer lands, rather
    // than a perpetual pulse. It leaves nothing animating behind it, so the
    // sheet costs no frames while it simply sits open.
    if (!allGood && !reduced) {
      final h = math.min(_Reading.halo.transform(t), redraw);
      if (h > 0 && h < 1) {
        canvas.drawCircle(
          centre,
          radius + 2 + h * 5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = settled.withValues(alpha: 0.42 * (1 - h)),
        );
      }
    }

    final n = tintTo.length;
    final gap = n > 1 ? _gap * (1 - close) : 0.0;
    final slice = math.pi * 2 / n;
    final arcRect = Rect.fromCircle(center: centre, radius: radius);
    final shift = AppMotion.easeOut.transform(retint.value);
    for (var i = 0; i < n; i++) {
      final fill = reduced ? 1.0 : reading.scan(i).transform(t);
      if (fill <= 0) continue;
      final answer = Color.lerp(tintFrom[i], tintTo[i], shift)!;
      final colour = Color.lerp(
        scanning,
        answer,
        reading.resolve(i).transform(t),
      )!;
      canvas.drawArc(
        arcRect,
        -math.pi / 2 + i * slice + gap / 2,
        (slice - gap) * fill,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          // Round caps read as separate pips while there are gaps; once the
          // ring closes they would overlap into lumps, so they go square.
          ..strokeCap = gap > 0.04 ? StrokeCap.round : StrokeCap.butt
          ..color = colour,
      );
    }

    if (!reduced) _paintRadar(canvas, centre, radius, t);
    _paintMark(
      canvas,
      centre,
      radius,
      math.min(_Reading.mark.transform(t), redraw),
      settled,
    );
  }

  /// A sweeping wedge inside the dial while the reading runs: the instrument
  /// visibly working, gone before the answer is drawn where it was.
  void _paintRadar(Canvas canvas, Offset centre, double radius, double t) {
    final opacity = 1 - _Reading.radarOut.transform(t);
    if (opacity <= 0 || t <= 0) return;
    final r = radius - 6;
    final angle = -math.pi / 2 + t * math.pi * 2.5;
    const wedge = 1.1;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: r),
      angle - wedge,
      wedge,
      true,
      Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: wedge,
          colors: [
            scanning.withValues(alpha: 0),
            scanning.withValues(alpha: 0.32 * opacity),
          ],
          transform: GradientRotation(angle - wedge),
        ).createShader(Rect.fromCircle(center: centre, radius: r)),
    );
    canvas.drawLine(
      centre,
      centre + Offset(math.cos(angle), math.sin(angle)) * r,
      Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = scanning.withValues(alpha: 0.85 * opacity),
    );
  }

  /// The answer, drawn rather than swapped in: a tick stroked left to right,
  /// or a bar dropping down with its dot landing under it.
  void _paintMark(
    Canvas canvas,
    Offset centre,
    double radius,
    double m,
    Color colour,
  ) {
    if (m <= 0) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = reduced ? colour.withValues(alpha: m) : colour;
    final progress = reduced ? 1.0 : m;
    if (allGood) {
      final path = Path()
        ..moveTo(centre.dx - radius * 0.3, centre.dy + radius * 0.02)
        ..lineTo(centre.dx - radius * 0.08, centre.dy + radius * 0.24)
        ..lineTo(centre.dx + radius * 0.32, centre.dy - radius * 0.2);
      _strokePartial(canvas, path, progress, stroke);
      return;
    }
    final bar = (progress / 0.7).clamp(0.0, 1.0);
    if (bar > 0) {
      final top = Offset(centre.dx, centre.dy - radius * 0.32);
      final bottom = Offset(centre.dx, centre.dy + radius * 0.06);
      canvas.drawLine(top, Offset.lerp(top, bottom, bar)!, stroke);
    }
    final dot = reduced
        ? 1.0
        : Curves.easeOutBack.transform(
            ((progress - 0.55) / 0.45).clamp(0.0, 1.0),
          );
    if (dot > 0) {
      canvas.drawCircle(
        Offset(centre.dx, centre.dy + radius * 0.3),
        2 * dot,
        Paint()..color = stroke.color,
      );
    }
  }

  static void _strokePartial(Canvas c, Path path, double t, Paint paint) {
    if (t >= 1) {
      c.drawPath(path, paint);
      return;
    }
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var left = total * t;
    for (final PathMetric metric in metrics) {
      if (left <= 0) break;
      c.drawPath(metric.extractPath(0, math.min(left, metric.length)), paint);
      left -= metric.length;
    }
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.allGood != allGood ||
      old.openedFromGood != openedFromGood ||
      old.reduced != reduced ||
      old.tintFrom != tintFrom ||
      old.tintTo != tintTo ||
      old.scanning != scanning ||
      old.track != track;
}

// ── Rows ─────────────────────────────────────────────────────────────────────

/// The checks, read in order by the line passing down through them.
class _CheckList extends StatelessWidget {
  const _CheckList({
    required this.rows,
    required this.sweep,
    required this.reading,
    required this.reduced,
  });

  final List<RecoveryCheck> rows;
  final Animation<double> sweep;
  final _Reading reading;
  final bool reduced;

  @override
  Widget build(BuildContext context) => ListView.separated(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
    itemCount: rows.length,
    separatorBuilder: (_, _) => const SizedBox(height: 10),
    // Each row reads its own slices of the one shared controller. Rows added
    // later by the stream land after the reading has finished, so every slice
    // is already complete — they simply appear, which is correct: they are an
    // update, not part of the original reading.
    itemBuilder: (context, i) => _CheckRow(
      check: rows[i],
      index: i,
      sweep: sweep,
      reading: reading,
      first: i == 0,
      last: i >= reading.count - 1,
      reduced: reduced,
    ),
  );
}

/// One checked thing. Healthy rows stay visually quiet — flat, no tint — so
/// the eye lands straight on whatever is actually wrong. An unhealthy one
/// flares as it is read, which is the only thing on this sheet asking to be
/// looked at.
class _CheckRow extends StatefulWidget {
  const _CheckRow({
    required this.check,
    required this.index,
    required this.sweep,
    required this.reading,
    required this.first,
    required this.last,
    required this.reduced,
  });

  final RecoveryCheck check;
  final int index;
  final Animation<double> sweep;
  final _Reading reading;
  final bool first;
  final bool last;
  final bool reduced;

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> with TickerProviderStateMixin {
  /// The mark's spring when the status changes while the sheet is open.
  /// Unbounded so the spring can overshoot past 1 and settle back, which is
  /// the part that makes it read as a physical thing landing.
  late final AnimationController _pop = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  /// The ring that pings out of the mark on that same change.
  late final AnimationController _ping = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
    value: 1,
  );

  /// The row's tint moving from its old status to its new one.
  late final AnimationController _tint = AnimationController(
    vsync: this,
    duration: AppMotion.card,
    value: 1,
  );

  late RecoveryStatus _fromStatus = widget.check.status;

  /// Whether the last live change made this row unhealthy, so the flare
  /// fires for a problem that just appeared, not for one that was just fixed.
  bool _brokeLive = false;

  late CurvedAnimation _entrance;
  late CurvedAnimation _scan;
  late CurvedAnimation _resolve;
  late CurvedAnimation _resolveBack;
  late CurvedAnimation _flare;

  static final SpringDescription _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 520,
    ratio: 0.42,
  );

  @override
  void initState() {
    super.initState();
    _slice();
  }

  void _slice() {
    final r = widget.reading;
    final i = widget.index;
    _entrance = CurvedAnimation(parent: widget.sweep, curve: r.entrance(i));
    _scan = CurvedAnimation(parent: widget.sweep, curve: r.scan(i));
    _resolve = CurvedAnimation(parent: widget.sweep, curve: r.resolve(i));
    _resolveBack = CurvedAnimation(
      parent: widget.sweep,
      curve: r.resolve(i, curve: Curves.easeOutBack),
    );
    _flare = CurvedAnimation(parent: widget.sweep, curve: r.flare(i));
  }

  void _disposeSlices() {
    for (final a in [_entrance, _scan, _resolve, _resolveBack, _flare]) {
      a.dispose();
    }
  }

  @override
  void didUpdateWidget(_CheckRow old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index ||
        old.sweep != widget.sweep ||
        old.reading != widget.reading) {
      _disposeSlices();
      _slice();
    }
    final from = old.check.status;
    final to = widget.check.status;
    if (from == to) return;
    _fromStatus = from;
    _tint.forward(from: 0);
    // A change before the line has even reached this row is not news — it
    // just becomes what the line finds.
    if (_resolve.value < 1 || widget.reduced) return;
    _brokeLive = !widget.check.isHealthy;
    _pop.value = 0.55;
    _pop.animateWith(SpringSimulation(_spring, 0.55, 1, 0));
    _ping.forward(from: 0);
  }

  @override
  void dispose() {
    _disposeSlices();
    _pop.dispose();
    _ping.dispose();
    _tint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final accent = RecoveryBanner.accentFor(check.status);
    final reduced = widget.reduced;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _mark(accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    check.label,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  _finding(accent),
                ],
              ),
            ),
          ],
        ),
        _actions(accent),
      ],
    );

    Widget row = AnimatedBuilder(
      animation: Listenable.merge([_resolve, _flare, _tint, _ping]),
      // Built once; only the panel behind it is redrawn per frame.
      child: RepaintBoundary(
        child: Padding(padding: const EdgeInsets.all(14), child: content),
      ),
      builder: (context, child) =>
          DecoratedBox(decoration: _panel(check, accent), child: child),
    );

    if (!reduced) {
      row = CustomPaint(
        foregroundPainter: _ScanLinePainter(
          scan: _scan,
          colour: AppColors.amber,
          first: widget.first,
          last: widget.last,
        ),
        child: row,
      );
    }

    return FadeTransition(
      opacity: _entrance,
      child: reduced
          ? row
          : SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.18),
                end: Offset.zero,
              ).animate(_entrance),
              child: row,
            ),
    );
  }

  /// The panel's tint, border and glow for this frame: neutral until the line
  /// has read the row, then whatever the row's status says, moving between
  /// statuses when the stream changes one.
  BoxDecoration _panel(RecoveryCheck check, Color accent) {
    final from = _statusPanel(_fromStatus);
    final to = _statusPanel(check.status);
    final shift = AppMotion.easeOut.transform(_tint.value);
    final status = BoxDecoration.lerp(from, to, shift)!;
    final read = _resolve.value;
    final neutral = _statusPanel(RecoveryStatus.ok);
    final panel = BoxDecoration.lerp(neutral, status, read)!;
    if (check.isHealthy || widget.reduced) return panel;
    // A broken row glows as it is read and then holds a low, steady halo.
    // Once the reading finishes nothing is animating, so an open sheet
    // schedules no frames — and a test can settle, which a perpetual pulse
    // never lets it do. The standing tint, border and mark are what carry
    // "still wrong"; the flare only says "look here first".
    final flare = math.max(
      read * (1 - _flare.value),
      _brokeLive ? 1 - _ping.value : 0.0,
    );
    return panel.copyWith(
      boxShadow: [
        BoxShadow(
          color: accent.withValues(alpha: 0.05 * read + 0.16 * flare),
          blurRadius: 20,
          spreadRadius: 1,
        ),
      ],
    );
  }

  static BoxDecoration _statusPanel(RecoveryStatus status) {
    final accent = RecoveryBanner.accentFor(status);
    final healthy =
        status == RecoveryStatus.ok || status == RecoveryStatus.unknown;
    return BoxDecoration(
      color: healthy ? accent.withAlpha(0) : accent.withAlpha(16),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: healthy ? AppColors.border : accent.withAlpha(110),
      ),
      boxShadow: [BoxShadow(color: accent.withAlpha(0), blurRadius: 20)],
    );
  }

  /// A quiet blank dot until the line reads the row, then the status mark
  /// springing in. A status change while open springs it again and sends a
  /// ping out of it.
  Widget _mark(Color accent) {
    final reduced = widget.reduced;
    final status = AnimatedSwitcher(
      duration: AppMotion.chip,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      child: Icon(
        RecoveryBanner.iconFor(widget.check.status),
        key: ValueKey(widget.check.status),
        color: accent,
        size: 18,
      ),
    );
    final landed = FadeTransition(
      opacity: _resolve,
      child: reduced
          ? status
          : ScaleTransition(
              scale: Tween<double>(begin: 0.4, end: 1).animate(_resolveBack),
              child: ScaleTransition(scale: _pop, child: status),
            ),
    );
    final pending = FadeTransition(
      opacity: ReverseAnimation(_resolve),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: AppColors.textSecondary.withValues(alpha: 0.6),
              width: 1.5,
            ),
          ),
        ),
      ),
    );
    return SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(
        painter: reduced ? null : _PingPainter(ping: _ping, colour: accent),
        child: Stack(fit: StackFit.expand, children: [pending, landed]),
      ),
    );
  }

  /// What was found. Its space is held from the first frame (a blank bar
  /// stands in for it), so a finding arriving never moves the rows below.
  Widget _finding(Color accent) {
    final check = widget.check;
    final text = AnimatedSwitcher(
      duration: AppMotion.card,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      transitionBuilder: HandOver.transition(),
      layoutBuilder: _startAligned,
      child: Text(
        check.detail,
        key: ValueKey(check.detail),
        style: TextStyle(
          color: check.isHealthy ? AppColors.textSecondary : accent,
          fontSize: 12,
          height: 1.45,
        ),
      ),
    );
    // Varied a little per row so the blanks read as text-to-come rather
    // than a column of identical bars.
    final blankWidth = 0.38 + (widget.index % 3) * 0.13;
    return Stack(
      children: [
        FadeTransition(
          opacity: _resolve,
          child: widget.reduced
              ? text
              : SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.45),
                    end: Offset.zero,
                  ).animate(_resolve),
                  child: text,
                ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: ReverseAnimation(_resolve),
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: FractionallySizedBox(
                  widthFactor: blankWidth,
                  child: Container(
                    height: 8,
                    margin: const EdgeInsets.only(top: 5),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The fixes. Present in the layout from the start but untouchable and
  /// invisible until the line has read the row: a fix offered before the
  /// problem is shown is a fix for nothing.
  Widget _actions(Color accent) {
    final actions = widget.check.actions;
    return _Resize(
      reduced: widget.reduced,
      child: actions.isEmpty
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AnimatedBuilder(
                animation: _resolve,
                builder: (context, child) =>
                    IgnorePointer(ignoring: _resolve.value < 1, child: child),
                child: FadeTransition(
                  opacity: _resolve,
                  child: RecoveryActionRow(actions: actions, accent: accent),
                ),
              ),
            ),
    );
  }
}

/// The reading head: a hairline with a short afterglow above it, crossing the
/// row top to bottom while [scan] runs. Consecutive rows hand the line on, so
/// down the list it reads as one line travelling.
class _ScanLinePainter extends CustomPainter {
  _ScanLinePainter({
    required this.scan,
    required this.colour,
    required this.first,
    required this.last,
  }) : super(repaint: scan);

  final Animation<double> scan;
  final Color colour;
  final bool first;
  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final v = scan.value;
    if (v <= 0 || v >= 1) return;
    // Only the very start and end of the whole pass fade; in between the
    // line is handed from row to row at full strength.
    var strength = 1.0;
    if (first) strength = math.min(strength, v / 0.2);
    if (last) strength = math.min(strength, (1 - v) / 0.2);
    strength = strength.clamp(0.0, 1.0);
    if (strength <= 0) return;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(14),
    );
    final y = size.height * v;
    canvas.save();
    canvas.clipRRect(rrect);
    const trail = 26.0;
    final glow = Rect.fromLTRB(0, y - trail, size.width, y);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            colour.withValues(alpha: 0),
            colour.withValues(alpha: 0.11 * strength),
          ],
        ).createShader(glow),
    );
    final line = Rect.fromLTWH(0, y - 0.75, size.width, 1.5);
    canvas.drawRect(
      line,
      Paint()
        ..shader = LinearGradient(
          colors: [
            colour.withValues(alpha: 0),
            colour.withValues(alpha: 0.9 * strength),
            colour.withValues(alpha: 0.9 * strength),
            colour.withValues(alpha: 0),
          ],
          stops: const [0, 0.18, 0.82, 1],
        ).createShader(line),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScanLinePainter old) =>
      old.colour != colour || old.first != first || old.last != last;
}

/// One ring pushing out of a row's mark when its status changes while open.
class _PingPainter extends CustomPainter {
  _PingPainter({required this.ping, required this.colour})
    : super(repaint: ping);

  final Animation<double> ping;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final p = ping.value;
    if (p <= 0 || p >= 1) return;
    final eased = Curves.easeOut.transform(p);
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2 + eased * 12,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * (1 - eased) + 0.5
        ..color = colour.withValues(alpha: 0.5 * (1 - eased)),
    );
  }

  @override
  bool shouldRepaint(_PingPainter old) => old.colour != colour;
}
