// widget_loop_animation_light.dart
//
// Light-palette twin of widget_loop_animation.dart — the Tark dial sitting on
// a phone's home screen, alive. Only the colors differ, so the geometry is
// reused from WidgetLoopPainter rather than copy-edited (the older loop
// animations in this folder predate that and duplicate their painters).

import 'package:flutter/material.dart';

import 'widget_loop_animation.dart';

// ── Palette ──────────────────────────────────────────────────────────────
const Color kAccentLight = Color(0xFFB26B00);
const Color kPhoneFillLight = Color(0xFFF6F1E7);
const Color kPhoneEdgeLight = Color(0xFFD6C9AE);
const Color kCardFillLight = Color(0xFFFFFDF7);
const Color kCardEdgeLight = Color(0xFFB9A987);
const Color kIconLight = Color(0xFFE4DAC4);
const Color kDimLight = Color(0xFF857A64);

const double kDurationSecondsLight = 4.0;

class WidgetLoopAnimationLight extends StatefulWidget {
  const WidgetLoopAnimationLight({super.key});

  @override
  State<WidgetLoopAnimationLight> createState() =>
      _WidgetLoopAnimationLightState();
}

class _WidgetLoopAnimationLightState extends State<WidgetLoopAnimationLight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: (kDurationSecondsLight * 1000).round()),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: WidgetLoopPainter(
            phase: _controller.value,
            accent: kAccentLight,
            phoneFill: kPhoneFillLight,
            phoneEdge: kPhoneEdgeLight,
            cardFill: kCardFillLight,
            cardEdge: kCardEdgeLight,
            icon: kIconLight,
            dim: kDimLight,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
