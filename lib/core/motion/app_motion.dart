import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's motion vocabulary.
///
/// Before this file, every animation picked its own curve and duration inline —
/// `easeOutQuart` in one widget, `easeOutCubic` in the next, 250ms beside
/// 420ms. Two elements moving at the same moment moved differently, which is
/// what makes an interface read as unsynchronised rather than designed. New
/// work reaches for these and nothing else.
///
/// Every value here is chosen against one hard constraint: 60fps on a Galaxy
/// S8+ (Mali-G71, Android 9), the floor device this app supports. That rules
/// out per-frame mask blurs and `ClipPath`, and it is why the primitives below
/// run **one** controller per page that children read through intervals,
/// instead of a ticker per row.
abstract final class AppMotion {
  /// Strong ease-out — the default for anything entering, leaving or settling.
  ///
  /// Flutter's built-ins are too weak to read as deliberate at these
  /// durations. Never ease-in on UI: it starts slow, which delays the exact
  /// moment the user is watching, and a 200ms ease-out *feels* faster than a
  /// 200ms ease-in.
  static const Cubic easeOut = Cubic(0.23, 1, 0.32, 1);

  /// [easeOut], mirrored — the curve for the *departing* half of a crossfade.
  ///
  /// `AnimatedSwitcher` hands `switchOutCurve` an animation that already runs
  /// 1 → 0, so passing [easeOut] there does not reverse it: the curve is
  /// sampled near its own flat tail for most of the transition, which holds the
  /// outgoing child at full opacity while the incoming one finishes arriving,
  /// then drops it in the last few frames. That is two beats where the whole
  /// point was one. Flipped, the outgoing child is worth exactly
  /// `1 - easeOut(t)` of the incoming one at every frame, so the pair sums to a
  /// constant and reads as a single dissolve.
  static const Curve leaving = FlippedCurve(easeOut);

  /// Strong ease-in-out, for something moving between two on-screen places
  /// where both ends are visible and the middle should carry speed.
  static const Cubic easeInOut = Cubic(0.77, 0, 0.175, 1);

  /// Almost no ease-in and a long settle. For sheets and route pushes —
  /// anything the user could plausibly have dragged instead.
  static const Cubic drawer = Cubic(0.32, 0.72, 0, 1);

  /// Press feedback. Long enough to see, short enough that it never delays the
  /// action it is confirming.
  static const Duration press = Duration(milliseconds: 120);

  /// Chips, badges, small state marks.
  static const Duration chip = Duration(milliseconds: 180);

  /// Cards, list rows, selection changes.
  static const Duration card = Duration(milliseconds: 220);

  /// Sheets and route transitions.
  static const Duration sheet = Duration(milliseconds: 320);

  /// One element's share of a page entrance — not the whole sequence, which
  /// runs longer as the stagger accumulates.
  static const Duration entrance = Duration(milliseconds: 380);

  /// The slow ambient pulse on a primary call to action.
  ///
  /// Deliberately far outside the UI-duration range: it is not responding to
  /// anything, it is breathing. Anything quicker reads as an alert, and this
  /// element's whole job is to look inviting rather than urgent.
  static const Duration pulse = Duration(milliseconds: 2000);

  /// How long a control stays in its "done" state after it is pressed.
  ///
  /// Long enough to be noticed by someone whose eyes were on the QR code
  /// rather than the button, short enough that the control is back to
  /// offering its action before anyone reaches for it again.
  static const Duration confirmHold = Duration(milliseconds: 2400);

  /// Gap between neighbouring items in an entrance. Below ~30ms the stagger
  /// stops being legible; above ~80ms the last row feels left behind.
  static const Duration stagger = Duration(milliseconds: 45);

  /// How far an entering element travels, in logical pixels. Small on purpose:
  /// the eye reads the direction, not the distance, and a long slide is the
  /// difference between "arrived" and "still arriving".
  static const double rise = 14;

  /// Whether the platform asked for less motion.
  ///
  /// "Less" is the operative word. Callers keep opacity and colour and drop
  /// travel — cutting to no transition at all is its own kind of jarring, and
  /// the fade is often the part that was carrying the meaning.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Fades and lifts a set of children into place, one shared controller for all
/// of them.
///
/// The controller count is the point. A ticker per row costs a `SchedulerBinding`
/// callback and a rebuild each, per frame, which is exactly the shape that
/// drops frames on the floor device; here the children are built once and the
/// per-frame work is two RenderObject transforms each — `FadeTransition` and
/// `SlideTransition` never rebuild their subtree.
///
/// [builder] receives the wrapped children so the caller keeps its own layout:
/// a `ListView`, a `Column`, anything.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({
    required this.children,
    required this.builder,
    this.beginOffset = const Offset(0, 1),
    super.key,
  });

  final List<Widget> children;
  final Widget Function(BuildContext context, List<Widget> children) builder;

  /// Direction of travel, in multiples of [AppMotion.rise]. Defaults to a rise
  /// from below; pass a horizontal offset for something that should read as
  /// arriving from the side.
  final Offset beginOffset;

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _totalDuration,
  );

  Duration get _totalDuration =>
      AppMotion.entrance + AppMotion.stagger * (widget.children.length - 1);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(StaggeredEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A list that grew or shrank re-times the sequence rather than replaying
    // it: rows already on screen must not flash back to transparent because a
    // sibling arrived.
    if (widget.children.length != oldWidget.children.length) {
      _controller
        ..duration = _totalDuration
        ..forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The slice of the sequence belonging to item [index].
  ///
  /// Each item gets the full [AppMotion.entrance] window, offset by its own
  /// stagger — so every item moves at an identical speed and only their start
  /// times differ. Giving each a *shorter* window instead is the usual mistake
  /// and it reads as the last items rushing to catch up.
  Animation<double> _slice(int index, int total) {
    final totalMs = _totalDuration.inMilliseconds;
    if (totalMs == 0) return const AlwaysStoppedAnimation<double>(1);
    final startMs = AppMotion.stagger.inMilliseconds * index;
    final begin = startMs / totalMs;
    final end = (startMs + AppMotion.entrance.inMilliseconds) / totalMs;
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(begin, end.clamp(begin, 1), curve: AppMotion.easeOut),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final total = widget.children.length;
    final wrapped = <Widget>[
      for (var i = 0; i < total; i++)
        _EntranceItem(
          // Keyed by position so re-ordering does not restart an item that is
          // already in place.
          key: ValueKey<int>(i),
          animation: _slice(i, total),
          // Reduced motion keeps the fade and the stagger — which is what
          // carries "these arrived in an order" — and drops only the travel.
          offset: reduced ? Offset.zero : widget.beginOffset,
          child: widget.children[i],
        ),
    ];
    return widget.builder(context, wrapped);
  }
}

class _EntranceItem extends StatelessWidget {
  const _EntranceItem({
    required this.animation,
    required this.offset,
    required this.child,
    super.key,
  });

  final Animation<double> animation;
  final Offset offset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (offset == Offset.zero) {
      return FadeTransition(opacity: animation, child: child);
    }
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        // Fractional so it scales with the row rather than being a fixed pixel
        // slide that reads differently on a tall card than a short one.
        position: Tween<Offset>(
          begin: offset * 0.08,
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }
}

/// Press feedback: a small settle under the finger, and a haptic tick.
///
/// The scale floor matters. Anything below ~0.94 reads as the control
/// retreating from the touch rather than acknowledging it, and nothing in the
/// physical world shrinks to nothing when pressed — which is the same reason
/// entrances start at 0.95 rather than 0.
class PressableScale extends StatefulWidget {
  const PressableScale({
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.borderRadius,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final BorderRadius? borderRadius;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value || widget.onTap == null) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        _set(true);
        HapticFeedback.selectionClick();
      },
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down && enabled ? widget.scale : 1,
        // Asymmetric on purpose: the press is instant feedback, the release is
        // the system answering. Same curve, and short enough at both ends that
        // a double-tap never queues up behind it.
        duration: AppMotion.press,
        curve: AppMotion.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A slow amber breath around a primary call to action.
///
/// One controller, and the only thing it drives is a `BoxShadow` alpha and a
/// border colour — no blur mask, no shader, no layout. [child] is passed
/// through `AnimatedBuilder`'s `child` slot so the subtree underneath is built
/// once and never rebuilt by the pulse.
///
/// Reserved for the single most important action on a screen. Two things
/// pulsing at once is two things asking to be pressed first.
class PulseGlow extends StatefulWidget {
  const PulseGlow({
    required this.child,
    required this.borderRadius,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool enabled;

  @override
  State<PulseGlow> createState() => _PulseGlowState();
}

class _PulseGlowState extends State<PulseGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );
  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PulseGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;
    if (widget.enabled) {
      _controller.repeat(reverse: true);
    } else {
      // Stops where it is and eases back to rest rather than snapping to zero
      // glow, which would read as the control being switched off.
      _controller.animateTo(0, duration: AppMotion.card);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A repeating animation is the one thing reduced-motion users should never
    // be given: it never stops, so there is no moment at which it is done.
    if (!widget.enabled || AppMotion.reduced(context)) return widget.child;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulse,
        child: widget.child,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(
                  alpha: 0.06 + 0.16 * _pulse.value,
                ),
                blurRadius: 28,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Holds a control in a "done" state for a beat after it acts.
///
/// Feedback belongs on the control that was pressed. A `SnackBar` cannot do
/// that job from inside a modal sheet at all: the sheet is drawn over the
/// `ScaffoldMessenger`, so the confirmation lands *underneath* it and, from
/// the user's side, pressing the button did nothing whatsoever.
///
/// [builder] is handed the current state and the trigger, so the control keeps
/// its own appearance and this widget only owns the timing:
///
/// ```dart
/// TapConfirmation(
///   builder: (context, confirmed, confirm) => MyButton(
///     icon: confirmed ? Icons.check_rounded : Icons.copy_rounded,
///     onTap: () async {
///       await doTheThing();
///       confirm();
///     },
///   ),
/// )
/// ```
///
/// Re-triggering restarts the hold rather than stacking timers, so a second
/// press reads as a second confirmation instead of cutting the first one
/// short.
class TapConfirmation extends StatefulWidget {
  const TapConfirmation({
    required this.builder,
    this.hold = AppMotion.confirmHold,
    super.key,
  });

  final Widget Function(BuildContext context, bool confirmed, VoidCallback confirm)
  builder;

  /// How long the confirmed state is held before the control returns.
  final Duration hold;

  @override
  State<TapConfirmation> createState() => _TapConfirmationState();
}

class _TapConfirmationState extends State<TapConfirmation> {
  Timer? _timer;
  bool _confirmed = false;

  void _confirm() {
    if (!mounted) return;
    _timer?.cancel();
    if (!_confirmed) setState(() => _confirmed = true);
    _timer = Timer(widget.hold, () {
      if (mounted) setState(() => _confirmed = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _confirmed, _confirm);
}
