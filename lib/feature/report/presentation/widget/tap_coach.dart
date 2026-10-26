import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/member_tap_hint.dart';

/// How long the coaching gets on screen before it counts as seen.
const Duration _kCoachFor = Duration(seconds: 9);

/// One rider's face, showing the gesture instead of describing it: a phantom
/// finger presses it (the face dips as if tapped) and a ripple runs out from
/// where it landed, every couple of seconds, until the hint is learned.
///
/// Only the first other rider in a roster is [active], so the room shows one
/// demonstration rather than a field of pulsing faces.
class TapCoachFace extends StatefulWidget {
  const TapCoachFace({
    required this.active,
    required this.size,
    required this.child,
    this.hint,
    super.key,
  });

  final bool active;
  final double size;
  final Widget child;

  /// Injected by tests; the app's own otherwise.
  final MemberTapHint? hint;

  @override
  State<TapCoachFace> createState() => _TapCoachFaceState();
}

class _TapCoachFaceState extends State<TapCoachFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  MemberTapHint get _hint => widget.hint ?? MemberTapHint.instance;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _hint.addListener(_sync);
      unawaited(_hint.load());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(TapCoachFace old) {
    super.didUpdateWidget(old);
    // The coached rider can change as people come and go.
    if (old.active != widget.active || old.hint != widget.hint) {
      if (old.active)
        (old.hint ?? MemberTapHint.instance).removeListener(_sync);
      if (widget.active) {
        _hint.addListener(_sync);
        unawaited(_hint.load());
      }
      _sync();
    }
  }

  /// Ticks only while there is something to demonstrate: an idle roster (and
  /// every one with the flag off) schedules no frames at all.
  void _sync() {
    if (!mounted) return;
    if (widget.active && _hint.showing) {
      _tap.loopUnlessReduced(context);
    } else if (_tap.isAnimating) {
      _tap.stop();
    }
  }

  @override
  void dispose() {
    if (widget.active) _hint.removeListener(_sync);
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return ListenableBuilder(
      listenable: _hint,
      builder: (context, child) {
        final on = _hint.showing;
        if (!on) return child!;
        final reduced = AppMotion.reduced(context);
        return AnimatedBuilder(
          animation: _tap,
          builder: (context, child) {
            // 0–0.12: the press; then the ripple runs while the face springs
            // back, and the rest of the beat is quiet.
            final t = _tap.value;
            final press = reduced
                ? 0.0
                : math.sin(math.pi * (t / 0.12).clamp(0.0, 1.0));
            return CustomPaint(
              key: const Key('tap-coach-face'),
              foregroundPainter: _RipplePainter(
                t: reduced ? 0.45 : t,
                color: AppColors.amber,
                radius: widget.size / 2,
              ),
              child: Transform.scale(scale: 1 - 0.07 * press, child: child),
            );
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _RipplePainter extends CustomPainter {
  _RipplePainter({required this.t, required this.color, required this.radius});

  final double t;
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (final delay in const [0.08, 0.24]) {
      final p = ((t - delay) / 0.6).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final eased = Curves.easeOut.transform(p);
      canvas.drawCircle(
        c,
        radius + 2 + 14 * eased,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4 * (1 - p) + 0.6
          ..color = color.withValues(alpha: 0.75 * (1 - p)),
      );
    }
    // Where the finger landed.
    final dot = (1 - (t / 0.3)).clamp(0.0, 1.0);
    if (dot > 0) {
      canvas.drawCircle(
        c,
        radius * 0.34 * (0.7 + 0.3 * dot),
        Paint()..color = Colors.white.withValues(alpha: 0.35 * dot),
      );
    }
  }

  @override
  bool shouldRepaint(_RipplePainter old) => old.t != t;
}

/// The one line of words that goes with the demonstration: a small callout
/// that grows out from under the coached rider, points up at their face, and
/// goes away for good once a card is opened, it is tapped, or it has been on
/// screen for a few seconds.
class TapCoachNote extends StatefulWidget {
  const TapCoachNote({
    required this.active,
    required this.faceCenter,
    this.hint,
    super.key,
  });

  final bool active;

  /// How far from the row's start edge the face's centre sits, so the
  /// callout's pointer lands on it.
  final double faceCenter;

  final MemberTapHint? hint;

  @override
  State<TapCoachNote> createState() => _TapCoachNoteState();
}

class _TapCoachNoteState extends State<TapCoachNote> {
  Timer? _timer;

  MemberTapHint get _hint => widget.hint ?? MemberTapHint.instance;

  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_hint.load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm(bool on) {
    if (on && _timer == null) {
      _timer = Timer(_kCoachFor, () => unawaited(_hint.learned()));
    } else if (!on) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _hint,
      builder: (context, _) {
        final on = widget.active && _hint.showing;
        _arm(on);
        return AnimatedSize(
          duration: AppMotion.sheet,
          curve: AppMotion.easeOut,
          alignment: AlignmentDirectional.topStart,
          child: AnimatedSwitcher(
            duration: AppMotion.card,
            switchInCurve: Curves.easeOutBack,
            switchOutCurve: AppMotion.leaving,
            // Start-aligned, so the pointer stays over the face it names.
            layoutBuilder: (current, previous) => Stack(
              alignment: AlignmentDirectional.topStart,
              children: [...previous, ?current],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: 0.85, end: 1.0).animate(animation),
                alignment: AlignmentDirectional.topStart.resolve(
                  Directionality.of(context),
                ),
                child: child,
              ),
            ),
            child: on
                ? _Callout(
                    key: const Key('tap-coach-note'),
                    pointerAt: widget.faceCenter,
                    onTap: () => unawaited(_hint.learned()),
                  )
                : const SizedBox(
                    key: Key('tap-coach-none'),
                    width: double.infinity,
                  ),
          ),
        );
      },
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.pointerAt, required this.onTap, super.key});

  final double pointerAt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final colour = AppColors.amber;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Semantics(
        liveRegion: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsetsDirectional.only(
                  start: math.max(0, pointerAt - 7),
                ),
                child: CustomPaint(
                  size: const Size(14, 7),
                  painter: _NotchPainter(colour),
                ),
              ),
              Container(
                padding: const EdgeInsetsDirectional.fromSTEB(10, 7, 12, 7),
                decoration: BoxDecoration(
                  color: colour,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.touch_app_rounded,
                      size: 17,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        s.member_tap_hint,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotchPainter extends CustomPainter {
  const _NotchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(0, size.height)
        ..lineTo(size.width / 2, 0)
        ..lineTo(size.width, size.height)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_NotchPainter old) => old.color != color;
}
