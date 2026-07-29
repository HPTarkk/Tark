import 'package:flutter/material.dart';

/// Animates text changes with a Telegram-style ticker: the incoming value
/// pushes in from the top while the outgoing value is pushed down and out
/// the bottom, both fading simultaneously.
class TickerText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final int? maxLines;
  final Duration duration;
  final Curve curve;

  const TickerText({
    super.key,
    required this.text,
    this.style,
    this.overflow,
    this.textAlign,
    this.maxLines,
    this.duration = const Duration(milliseconds: 250),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<TickerText> createState() => _TickerTextState();
}

class _TickerTextState extends State<TickerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  String? _previousText;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..value = 1;
    _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
  }

  @override
  void didUpdateWidget(covariant TickerText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _previousText = oldWidget.text;
      _controller.duration = widget.duration;
      _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
      _controller
        ..value = 0
        ..forward();
    } else if (oldWidget.duration != widget.duration ||
        oldWidget.curve != widget.curve) {
      _controller.duration = widget.duration;
      _animation = CurvedAnimation(parent: _controller, curve: widget.curve);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Text _text(String value) => Text(
    value,
    style: widget.style,
    overflow: widget.overflow,
    textAlign: widget.textAlign,
    maxLines: widget.maxLines,
  );

  /// Which edge the stacked in/out lines are pinned to.
  ///
  /// This must be DIRECTIONAL, and that is the whole subtlety here. While one
  /// line is replacing another the stack is as wide as BOTH of them, and it
  /// shrinks to just the incoming line only once the swap finishes. So the
  /// edge the text is pinned to has to be the same edge the parent will
  /// ultimately align the narrower box to — otherwise the text is laid out
  /// against one side of an over-wide box and then lands on the other.
  ///
  /// Pinning to a physical left edge got exactly that wrong under RTL: a
  /// `Column(crossAxisAlignment: start)` puts the box's start edge on the
  /// RIGHT in Persian, so the line animated against the left of the wide box
  /// and snapped rightwards the instant it shrank — seen as the text sliding
  /// in around the middle and jumping to the start at the end.
  ///
  /// Note [AlignmentDirectional] already resolves against [Directionality],
  /// so these must NOT also switch on it — doing both flips twice and puts
  /// RTL back on the physical left.
  AlignmentGeometry get _alignment => switch (widget.textAlign) {
    TextAlign.center => Alignment.center,
    // left/right name physical sides rather than reading-order edges, so they
    // stay physical.
    TextAlign.left => Alignment.centerLeft,
    TextAlign.right => Alignment.centerRight,
    TextAlign.end => AlignmentDirectional.centerEnd,
    // start, justify, and null (the common case — the mic labels pass no
    // alignment at all) all follow the reading direction.
    _ => AlignmentDirectional.centerStart,
  };

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final t = _animation.value;
          final showPrevious = _previousText != null && t < 1;
          return Stack(
            alignment: _alignment,
            fit: StackFit.passthrough,
            children: [
              if (showPrevious)
                FractionalTranslation(
                  translation: Offset(0, t),
                  child: Opacity(opacity: 1 - t, child: _text(_previousText!)),
                ),
              FractionalTranslation(
                translation: Offset(0, t - 1),
                child: Opacity(opacity: t, child: _text(widget.text)),
              ),
            ],
          );
        },
      ),
    );
  }
}
