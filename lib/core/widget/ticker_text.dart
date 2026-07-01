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

  Alignment get _alignment {
    switch (widget.textAlign) {
      case TextAlign.center:
        return Alignment.center;
      case TextAlign.right:
      case TextAlign.end:
        return Alignment.centerRight;
      default:
        return Alignment.centerLeft;
    }
  }

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
