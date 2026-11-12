import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../motion/app_motion.dart';
import '../theme/app_colors.dart';

/// One choice on a [SegmentedTrack].
@immutable
class TrackSegment<T> {
  const TrackSegment({
    required this.value,
    required this.icon,
    required this.label,
    this.mark,
    this.dimmed = false,
    this.semanticsHint,
    this.segmentKey,
  });

  final T value;
  final IconData icon;
  final String label;

  /// A small mark after the label: a lock, a beta dot.
  final Widget? mark;

  /// Drawn quieter while not selected — "not yours yet". Still tappable: the
  /// tap is what explains why.
  final bool dimmed;

  /// Read after the label by a screen reader, e.g. "Needs a subscription".
  final String? semanticsHint;

  final Key? segmentKey;
}

/// The app's one "pick one of a few" control: segments on a track, and a
/// thumb that travels between them.
///
/// There were three of these, each drawn by hand — the connection picker in
/// Settings, the Wi-Fi/Hotspot tabs, the method on an invite — and each
/// snapped its highlight from one segment to the next by fading two boxes.
/// Now they are one control with one motion:
///
/// * the thumb rides a spring from segment to segment, stretching a touch in
///   flight, and the labels warm to amber as it arrives under them;
/// * it can be dragged — it follows the finger and, on release, settles on
///   the segment it is nearest (or was flung toward);
/// * it always comes to rest on [value]. A pick the owner turns down (a
///   locked choice whose paywall was closed) simply springs back;
/// * the track follows the reading direction, so the first segment sits at
///   the right in Persian;
/// * under reduced motion the thumb moves in a short straight ease.
///
/// [stacked] puts each icon over its label, for three or more segments that
/// would not fit side by side.
class SegmentedTrack<T> extends StatefulWidget {
  const SegmentedTrack({
    required this.segments,
    required this.value,
    required this.onChanged,
    this.onReselected,
    this.semanticsLabel,
    this.stacked = false,
    super.key,
  }) : assert(segments.length >= 2);

  final List<TrackSegment<T>> segments;

  /// The selected value. One not among [segments] rests on the first.
  final T value;
  final ValueChanged<T> onChanged;

  /// A tap on the segment that is already selected. For a selection that is
  /// shown but not yet the person's to use (a locked default), where the tap
  /// is how they ask for it.
  final ValueChanged<T>? onReselected;
  final String? semanticsLabel;
  final bool stacked;

  @override
  State<SegmentedTrack<T>> createState() => _SegmentedTrackState<T>();
}

class _SegmentedTrackState<T> extends State<SegmentedTrack<T>>
    with SingleTickerProviderStateMixin {
  static const _inset = 4.0;

  /// A little under critical damping: one small overshoot, then still.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 520,
    damping: 34,
  );

  /// The thumb's place on the track, in segments: 0 is the first.
  late final AnimationController _thumb = AnimationController.unbounded(
    vsync: this,
    value: _target,
  );

  bool _dragging = false;

  int get _last => widget.segments.length - 1;

  double get _target {
    final index = widget.segments.indexWhere((s) => s.value == widget.value);
    return (index < 0 ? 0 : index).toDouble();
  }

  @override
  void didUpdateWidget(SegmentedTrack<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragging) return;
    if (oldWidget.value != widget.value ||
        oldWidget.segments.length != widget.segments.length) {
      _settle();
    }
  }

  @override
  void dispose() {
    _thumb.dispose();
    super.dispose();
  }

  /// Brings the thumb to rest on [SegmentedTrack.value], carrying [velocity]
  /// (in segments per second) from a fling.
  void _settle({double velocity = 0}) {
    final target = _target;
    if (AppMotion.reduced(context)) {
      _thumb.animateTo(
        target,
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
      );
      return;
    }
    if ((_thumb.value - target).abs() < 0.001 && velocity.abs() < 0.01) {
      _thumb.value = target;
      return;
    }
    _thumb.animateWith(
      SpringSimulation(_spring, _thumb.value, target, velocity),
    );
  }

  void _pick(int index, {double velocity = 0}) {
    final segment = widget.segments[index];
    if (segment.value != widget.value) {
      HapticFeedback.selectionClick();
      widget.onChanged(segment.value);
    } else if (velocity == 0) {
      // A tap, not a drag that ended where it began.
      widget.onReselected?.call(segment.value);
    }
    // Refused, or decided later: until [value] changes the thumb belongs
    // where it was.
    if (mounted) _settle(velocity: velocity);
  }

  int get _sign => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _dragBy(double delta, double segmentWidth) {
    if (segmentWidth <= 0) return;
    _thumb.value = (_thumb.value + _sign * delta / segmentWidth).clamp(
      -0.06,
      _last + 0.06,
    );
  }

  void _dragEnd(double velocity, double segmentWidth) {
    _dragging = false;
    final perSecond = segmentWidth <= 0 ? 0.0 : _sign * velocity / segmentWidth;
    final double aim = perSecond.abs() > 1.2
        ? (perSecond > 0 ? _thumb.value.ceil() : _thumb.value.floor())
              .toDouble()
        : _thumb.value.roundToDouble();
    _pick(aim.clamp(0, _last).toInt(), velocity: perSecond);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.segments.length;
    return Semantics(
      container: true,
      label: widget.semanticsLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = (constraints.maxWidth - _inset * 2) / count;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              _dragging = true;
              _thumb.stop();
            },
            onHorizontalDragUpdate: (details) =>
                _dragBy(details.primaryDelta ?? 0, segmentWidth),
            onHorizontalDragEnd: (details) =>
                _dragEnd(details.primaryVelocity ?? 0, segmentWidth),
            onHorizontalDragCancel: () {
              _dragging = false;
              _settle();
            },
            child: Container(
              padding: const EdgeInsets.all(_inset),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: AnimatedBuilder(
                      animation: _thumb,
                      builder: (context, child) {
                        final t = _thumb.value;
                        // Stretches a touch between segments, the way
                        // something with a little give does; exact at rest.
                        final stretch =
                            1 +
                            0.10 * math.sin(math.pi * (t - t.floor())).abs();
                        final x = count == 1 ? 0.0 : t / _last * 2 - 1;
                        return Align(
                          alignment: AlignmentDirectional(x, 0),
                          child: SizedBox(
                            width: segmentWidth,
                            height: double.infinity,
                            child: Transform.scale(
                              scaleX: stretch,
                              child: child,
                            ),
                          ),
                        );
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.amber.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppColors.amber.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: widget.stacked ? 50 : 38,
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < count; i++)
                            _Segment<T>(
                              key: widget.segments[i].segmentKey,
                              segment: widget.segments[i],
                              thumb: _thumb,
                              at: i.toDouble(),
                              selected:
                                  widget.segments[i].value == widget.value,
                              stacked: widget.stacked,
                              onTap: () => _pick(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One segment's ink. It warms to amber as the thumb arrives under it and
/// cools as it leaves, read straight off the thumb's position, so a drag
/// tints the labels continuously.
class _Segment<T> extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.thumb,
    required this.at,
    required this.selected,
    required this.stacked,
    required this.onTap,
    super.key,
  });

  final TrackSegment<T> segment;
  final Animation<double> thumb;
  final double at;
  final bool selected;
  final bool stacked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hint = segment.semanticsHint;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: hint == null ? segment.label : '${segment.label}. $hint',
        excludeSemantics: true,
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedBuilder(
            animation: thumb,
            builder: (context, _) {
              final near = (1 - (thumb.value - at).abs()).clamp(0.0, 1.0);
              final resting = segment.dimmed
                  ? AppColors.textSecondary.withValues(alpha: 0.55)
                  : AppColors.textSecondary;
              final color = Color.lerp(resting, AppColors.amber, near)!;
              final label = Text(
                segment.label,
                maxLines: stacked ? 2 : 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: stacked ? 11.5 : 13.5,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                ),
              );
              final mark = segment.mark;
              if (stacked) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 6,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(segment.icon, size: 18, color: color),
                          if (mark != null)
                            PositionedDirectional(
                              end: -12,
                              top: -5,
                              child: mark,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      label,
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(segment.icon, size: 18, color: color),
                    const SizedBox(width: 7),
                    Flexible(child: label),
                    if (mark != null) ...[const SizedBox(width: 5), mark],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
