import 'dart:math' as math;

import 'package:flutter/material.dart';
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
/// is: a ring that draws itself once on open, a sweep that passes down the
/// rows, and the rows themselves landing in order behind it. That sequence is
/// load-bearing rather than decorative — a list of green ticks that is simply
/// *present* the instant the sheet opens looks like a static picture of
/// reassurance, and people do not believe it. Watching it resolve is what
/// makes the verdict read as a result.
///
/// Fed by a stream so the rows correct themselves while the sheet is open:
/// the user grants the mic permission from the row's own button, comes back,
/// and watches it turn green without having to close and reopen anything.
Future<void> showRecoverySheet(
  BuildContext context, {
  required List<RecoveryCheck> initial,
  required Stream<List<RecoveryCheck>> checks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => _RecoverySheet(initial: initial, checks: checks),
  );
}

class _RecoverySheet extends StatefulWidget {
  const _RecoverySheet({required this.initial, required this.checks});

  final List<RecoveryCheck> initial;
  final Stream<List<RecoveryCheck>> checks;

  @override
  State<_RecoverySheet> createState() => _RecoverySheetState();
}

class _RecoverySheetState extends State<_RecoverySheet>
    with TickerProviderStateMixin {
  /// Runs once on open: the ring draws, the sweep falls, the verdict lands.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  /// Which status the verdict last settled on, so a change while the sheet is
  /// open can buzz rather than silently redrawing.
  bool? _lastAllGood;

  @override
  void initState() {
    super.initState();
    _sweep.forward();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  void _onVerdict(bool allGood) {
    if (_lastAllGood == allGood) return;
    final first = _lastAllGood == null;
    _lastAllGood = allGood;
    // Only once the reading has actually finished, and never for the initial
    // state — a haptic on open would be the sheet congratulating itself.
    if (first) return;
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
          border: Border.all(
            color: AppColors.amber.withValues(alpha: 0.22),
          ),
        ),
        child: StreamBuilder<List<RecoveryCheck>>(
          stream: widget.checks,
          initialData: widget.initial,
          builder: (context, snapshot) {
            final rows = snapshot.data ?? widget.initial;
            final broken = [
              for (final check in rows)
                if (!check.isHealthy) check,
            ];
            final allGood = broken.isEmpty;
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _onVerdict(allGood),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Grabber(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: _Verdict(
                    sweep: _sweep,
                    allGood: allGood,
                    brokenCount: broken.length,
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
                    reduced: reduced,
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

/// The reading: a ring that fills as the check runs, then holds the answer.
class _Verdict extends StatelessWidget {
  const _Verdict({
    required this.sweep,
    required this.allGood,
    required this.brokenCount,
    required this.total,
    required this.title,
    required this.detail,
    required this.reduced,
  });

  final Animation<double> sweep;
  final bool allGood;
  final int brokenCount;
  final int total;
  final String title;
  final String detail;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final settled = allGood ? AppColors.green : AppColors.amber;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: sweep,
            builder: (context, _) {
              // The ring fills over the first two-thirds and the colour
              // resolves over the last third, so the answer arrives *after*
              // the measurement rather than being asserted alongside it.
              final progress = reduced
                  ? 1.0
                  : Curves.easeInOut.transform(
                      (sweep.value / 0.66).clamp(0.0, 1.0),
                    );
              final resolve = reduced
                  ? 1.0
                  : Curves.easeOut.transform(
                      ((sweep.value - 0.6) / 0.4).clamp(0.0, 1.0),
                    );
              // A single halo pushing out of the ring as the answer lands,
              // rather than a perpetual pulse. It fires once, on the frame the
              // verdict resolves, which is the moment worth marking — and it
              // leaves nothing animating behind it, so the sheet costs no
              // frames while it simply sits open.
              final breath = allGood || reduced
                  ? 0.0
                  : Curves.easeOut.transform(resolve);
              return SizedBox(
                width: 58,
                height: 58,
                child: CustomPaint(
                  painter: _VerdictRingPainter(
                    progress: progress,
                    resolve: resolve,
                    breath: breath,
                    scanning: AppColors.amber,
                    settled: settled,
                    track: AppColors.border,
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: AppMotion.card,
                      switchInCurve: AppMotion.easeOut,
                      child: resolve < 0.5
                          ? Icon(
                              Icons.radar_rounded,
                              key: const ValueKey('scanning'),
                              size: 22,
                              color: AppColors.amber,
                            )
                          : Icon(
                              allGood
                                  ? Icons.check_rounded
                                  : Icons.priority_high_rounded,
                              key: ValueKey(allGood),
                              size: 24,
                              color: settled,
                            ),
                    ),
                  ),
                ),
              );
            },
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
              // Swapped rather than re-styled, so a verdict that changes while
              // the sheet is open reads as new information arriving.
              AnimatedSwitcher(
                duration: AppMotion.card,
                switchInCurve: AppMotion.easeOut,
                child: Text(
                  detail,
                  key: ValueKey(allGood),
                  style: TextStyle(
                    color: allGood ? AppColors.green : AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
              if (!allGood) ...[
                const SizedBox(height: 7),
                _CountPill(broken: brokenCount, total: total),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.broken, required this.total});

  final int broken;
  final int total;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: AppColors.amber.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
    ),
    // Counts stay LTR in Persian: "2 / 5" reversed reads as a different ratio.
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        '$broken / $total'.localized(context),
        style: TextStyle(
          color: AppColors.amber,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    ),
  );
}

class _VerdictRingPainter extends CustomPainter {
  _VerdictRingPainter({
    required this.progress,
    required this.resolve,
    required this.breath,
    required this.scanning,
    required this.settled,
    required this.track,
  });

  /// 0..1 sweep of the arc.
  final double progress;

  /// 0..1 crossfade from the scanning colour to the answer.
  final double resolve;

  /// 0..1 breath, only on an unhealthy verdict.
  final double breath;

  final Color scanning;
  final Color settled;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centre = rect.center;
    final radius = size.shortestSide / 2 - 3;
    final colour = Color.lerp(scanning, settled, resolve)!;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );

    if (breath > 0) {
      canvas.drawCircle(
        centre,
        radius + 2 + breath * 4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = colour.withValues(alpha: 0.42 * (1 - breath)),
      );
    }

    if (progress <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      progress * math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = colour,
    );
  }

  @override
  bool shouldRepaint(_VerdictRingPainter old) =>
      old.progress != progress ||
      old.resolve != resolve ||
      old.breath != breath ||
      old.settled != settled;
}

// ── Rows ─────────────────────────────────────────────────────────────────────

/// The checks, landing in order behind the sweep.
class _CheckList extends StatelessWidget {
  const _CheckList({
    required this.rows,
    required this.sweep,
    required this.reduced,
  });

  final List<RecoveryCheck> rows;
  final Animation<double> sweep;
  final bool reduced;

  @override
  Widget build(BuildContext context) => ListView.separated(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
    itemCount: rows.length,
    separatorBuilder: (_, _) => const SizedBox(height: 10),
    itemBuilder: (context, i) {
      // Each row gets its own slice of the one shared controller. Rows added
      // later by the stream arrive past the end of the sweep, whose value has
      // already reached 1 — so they simply appear, which is correct: they are
      // an update, not part of the original reading.
      final start = (0.18 + i * 0.09).clamp(0.0, 0.85);
      final slice = CurvedAnimation(
        parent: sweep,
        curve: Interval(start, (start + 0.3).clamp(0.0, 1.0)),
      );
      return _CheckRow(check: rows[i], entrance: slice, reduced: reduced);
    },
  );
}

/// One checked thing. Healthy rows stay visually quiet — flat, no tint — so
/// the eye lands straight on whatever is actually wrong. An unhealthy one
/// breathes, which is the only thing on this sheet asking to be looked at.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.check,
    required this.entrance,
    required this.reduced,
  });

  final RecoveryCheck check;
  final Animation<double> entrance;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final accent = RecoveryBanner.accentFor(check.status);
    final healthy = check.isHealthy;
    final content = _content(context, accent: accent, healthy: healthy);
    return FadeTransition(
      opacity: entrance,
      child: reduced
          ? content
          : SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.22),
                end: Offset.zero,
              ).animate(entrance),
              child: content,
            ),
    );
  }

  Widget _content(
    BuildContext context, {
    required Color accent,
    required bool healthy,
  }) {
    final body = AnimatedContainer(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: healthy ? Colors.transparent : accent.withAlpha(16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: healthy ? AppColors.border : accent.withAlpha(110),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cross-fades on status change so a row going green while the
              // sheet is open reads as a result, not a repaint.
              AnimatedSwitcher(
                duration: AppMotion.card,
                switchInCurve: AppMotion.easeOut,
                child: Icon(
                  RecoveryBanner.iconFor(check.status),
                  key: ValueKey(check.status),
                  color: accent,
                  size: 18,
                ),
              ),
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
                    Text(
                      check.detail,
                      style: TextStyle(
                        color: healthy ? AppColors.textSecondary : accent,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (check.actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            RecoveryActionRow(actions: check.actions, accent: accent),
          ],
        ],
      ),
    );
    if (healthy || reduced) return body;
    // A broken row glows as it lands and then holds a low, steady halo. Once
    // the entrance finishes nothing is animating, so an open sheet schedules
    // no frames — and a test can settle, which a perpetual pulse never lets
    // it do. The standing tint, border and icon are what carry "still wrong";
    // the flare only says "look here first".
    //
    // Only the glow is rebuilt per frame; the row is passed through `child`
    // and built once.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: entrance,
        child: body,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(
                  alpha: 0.05 + 0.14 * (1 - entrance.value),
                ),
                blurRadius: 20,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}
