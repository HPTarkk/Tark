import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/recovery/recovery_banner.dart';
import '../../../../core/recovery/recovery_check.dart';
import '../../../../core/theme/app_colors.dart';

/// The sheet's hero visual: a radar scanning outward while checks resolve,
/// each one landing as a blip at its own position around the ring, and a
/// one-shot bloom the instant the picture is complete — the radio/signal
/// motif this app already speaks (onboarding's signal meter, the channel
/// page's visualizer pill), not a generic spinner.
///
/// Deliberately one continuous motion (the sweep) plus one settling beat
/// (the bloom), not several competing effects — the sweep itself stops the
/// moment it isn't needed, and the bloom plays exactly once per resolution.
/// Everything here animates via [Transform]/[Opacity]/[AnimatedContainer]
/// driven by two controllers; nothing repaints its [CustomPainter] on a
/// per-frame rebuild, and the only blur is a small static shadow on an
/// already-resolved dot (never animated), which is what keeps this cheap on
/// the low-end floor.
class SignalRadar extends StatefulWidget {
  const SignalRadar({
    super.key,
    required this.checks,
    required this.isComplete,
    required this.hasBlocking,
    required this.hasOnlyWarning,
  });

  /// The sheet's visible rows, in display order — null for a slot still
  /// pending.
  final List<RecoveryCheck?> checks;
  final bool isComplete;
  final bool hasBlocking;
  final bool hasOnlyWarning;

  @override
  State<SignalRadar> createState() => _SignalRadarState();
}

class _SignalRadarState extends State<SignalRadar>
    with TickerProviderStateMixin {
  static const _size = 152.0;

  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _bloom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  );

  @override
  void initState() {
    super.initState();
    // Already resolved on first frame (a fixed test fixture, or a re-open
    // after the answer was already known) — settle silently, no replay.
    if (widget.isComplete) _bloom.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than initState, because reduced motion is read from
    // MediaQuery, and so it follows the setting if it changes mid-check.
    _syncSweep();
  }

  @override
  void didUpdateWidget(covariant SignalRadar old) {
    super.didUpdateWidget(old);
    if (!old.isComplete && widget.isComplete) {
      // Reduced motion lands on the settled state without the expanding ring.
      if (AppMotion.reduced(context)) {
        _bloom.value = 1;
      } else {
        _bloom.forward(from: 0);
      }
      HapticFeedback.mediumImpact();
    } else if (old.isComplete && !widget.isComplete) {
      // A remediation action re-opened the question (e.g. "Allow mic" is
      // re-running the probe) — go back to scanning, allow the bloom again.
      _bloom.value = 0;
    }
    _syncSweep();
  }

  /// Runs the sweep only while a check is still pending, and never under
  /// reduced motion: a loop has no end, so there is no moment it is done.
  void _syncSweep() {
    final shouldSweep = !widget.isComplete && !AppMotion.reduced(context);
    if (shouldSweep && !_sweep.isAnimating) {
      _sweep.repeat();
    } else if (!shouldSweep && _sweep.isAnimating) {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    _bloom.dispose();
    super.dispose();
  }

  Color get _accent => !widget.isComplete
      ? AppColors.amber
      : widget.hasBlocking
      ? AppColors.red
      : widget.hasOnlyWarning
      ? AppColors.amber
      : AppColors.green;

  IconData get _centerIcon => !widget.isComplete
      ? Icons.podcasts_rounded
      : widget.hasBlocking
      ? Icons.priority_high_rounded
      : widget.hasOnlyWarning
      ? Icons.warning_amber_rounded
      : Icons.check_rounded;

  /// Everything resolved and nothing to fix: the one outcome that earns an
  /// overshoot. A warning or a failure settles without a bounce.
  bool get _passed =>
      widget.isComplete && !widget.hasBlocking && !widget.hasOnlyWarning;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return RepaintBoundary(
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // A soft, static glow behind the whole dial — recomputed only
            // when the accent colour changes (a status transition), never
            // per animation frame, which is what keeps a blur affordable
            // here (see the low-end-device-floor rule this app holds
            // everywhere else: the expensive thing is a blur redrawn every
            // tick, not one that sits still between real state changes).
            AnimatedContainer(
              duration: AppMotion.card,
              curve: AppMotion.easeOut,
              width: _size * 0.82,
              height: _size * 0.82,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: _accent.withAlpha(70),
                    blurRadius: 34,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
            CustomPaint(
              size: const Size(_size, _size),
              painter: _RadarRingsPainter(color: AppColors.border),
            ),
            AnimatedBuilder(
              animation: _sweep,
              builder: (context, child) => Opacity(
                opacity: widget.isComplete ? 0 : 1,
                child: Transform.rotate(
                  angle: _sweep.value * 2 * math.pi,
                  child: child,
                ),
              ),
              child: RepaintBoundary(
                child: CustomPaint(
                  size: const Size(_size, _size),
                  painter: _RadarSweepPainter(color: _accent),
                ),
              ),
            ),
            AnimatedBuilder(
              animation: _bloom,
              builder: (context, child) {
                final t = _bloom.value;
                if (t <= 0) return const SizedBox.shrink();
                return Opacity(
                  opacity: (1 - t).clamp(0.0, 1.0),
                  child: Transform.scale(scale: 0.55 + t * 0.85, child: child),
                );
              },
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _accent, width: 2),
                ),
              ),
            ),
            for (var i = 0; i < widget.checks.length; i++)
              _blip(i, widget.checks[i], reduced: reduced),
            AnimatedSwitcher(
              duration: AppMotion.card,
              transitionBuilder: (child, animation) => reduced
                  ? FadeTransition(opacity: animation, child: child)
                  : ScaleTransition(
                      scale: CurvedAnimation(
                        parent: animation,
                        curve: _passed ? Curves.easeOutBack : AppMotion.easeOut,
                      ),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
              child: Container(
                key: ValueKey(_centerIcon),
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _accent.withAlpha(28),
                  border: Border.all(color: _accent.withAlpha(160)),
                ),
                child: Icon(_centerIcon, color: _accent, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _blip(int index, RecoveryCheck? check, {required bool reduced}) {
    final angle = -math.pi / 2 + index * (2 * math.pi / widget.checks.length);
    final radius = _size / 2 - 10;
    final offset = Offset(math.cos(angle), math.sin(angle)) * radius;
    final resolved = check != null;
    final color = resolved
        ? RecoveryBanner.accentFor(check.status)
        : AppColors.textSecondary;
    // Pending contacts stay dimly visible rather than invisible — the dial
    // reads as "6 things being tracked" from the first frame, each one
    // popping bright and full-size the instant it resolves, instead of
    // the ring looking sparse until results start arriving.
    return Transform.translate(
      offset: offset,
      child: AnimatedScale(
        scale: resolved ? 1.0 : 0.55,
        // Reduced motion jumps to the new size; the colour change below
        // still eases, and it carries the meaning on its own.
        duration: reduced ? Duration.zero : AppMotion.card,
        curve: resolved && check.isHealthy
            ? Curves.easeOutBack
            : AppMotion.easeOut,
        child: AnimatedContainer(
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: resolved ? color : color.withAlpha(70),
            boxShadow: resolved
                ? [BoxShadow(color: color.withAlpha(140), blurRadius: 5)]
                : null,
          ),
        ),
      ),
    );
  }
}

/// Faint static rings — the "radar screen" backdrop. Painted once per
/// [color] change (the theme flipping), never per animation frame.
class _RadarRingsPainter extends CustomPainter {
  const _RadarRingsPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final fraction in [1.0, 0.68, 0.36]) {
      canvas.drawCircle(center, maxRadius * fraction, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarRingsPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// A near-fully-transparent disc with one bright trailing edge — rotated as
/// a whole by the parent [Transform.rotate], so this never repaints for the
/// spin itself, only if [color] changes (a status flip mid-scan).
class _RadarSweepPainter extends CustomPainter {
  const _RadarSweepPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = SweepGradient(
        colors: [color.withAlpha(0), color.withAlpha(0), color.withAlpha(150)],
        stops: const [0.0, 0.72, 1.0],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _RadarSweepPainter oldDelegate) =>
      oldDelegate.color != color;
}
