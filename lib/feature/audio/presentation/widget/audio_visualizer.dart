import 'dart:math';

import 'package:flutter/material.dart';

class AudioVisualizer extends StatefulWidget {
  final List<double> samples;
  final double rms;
  final int barCount;
  final Color? color;

  const AudioVisualizer({
    super.key,
    required this.samples,
    required this.rms,
    this.barCount = 32,
    this.color,
  });

  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  List<double> _animatedSamples = [];

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _animatedSamples = List.filled(widget.barCount, 0);

    _controller.addListener(() {
      setState(() {});
    });

    _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);

    final samples = widget.samples;
    if (samples.isEmpty) return;

    // Downsample or map to barCount
    final step = max(1, samples.length ~/ widget.barCount);
    _animatedSamples = List.generate(widget.barCount, (i) {
      final index = i * step;
      return samples[min(index, samples.length - 1)].abs();
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _VisualizerPainter(
        samples: _animatedSamples,
        rms: widget.rms,
        animationValue: _controller.value,
        color: widget.color ?? Theme.of(context).colorScheme.primary,
      ),
      size: Size.infinite,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _VisualizerPainter extends CustomPainter {
  final List<double> samples;
  final double rms;
  final double animationValue;
  final Color color;

  _VisualizerPainter({
    required this.samples,
    required this.rms,
    required this.animationValue,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;

    final barWidth = size.width / samples.length;
    final centerY = size.height / 2;
    final shaderRect = Rect.fromLTWH(0, 0, size.width, size.height);

    final gradient = LinearGradient(
      colors: [
        color.withValues(alpha: .7),
        color,
        color.withValues(alpha: .9),
      ],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );

    final paint = Paint()
      ..shader = gradient.createShader(shaderRect)
      ..style = PaintingStyle.fill;

    // Single ambient glow for the whole visualizer — one GPU pass instead of
    // 48 separate MaskFilter.blur calls (one per bar), which was very expensive.
    if (rms > 0.01) {
      canvas.drawRect(
        shaderRect,
        Paint()
          ..color = color.withValues(alpha: (rms * 0.35).clamp(0.0, 0.25))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }

    for (int i = 0; i < samples.length; i++) {
      final amplitude = samples[i];
      final animatedAmplitude = amplitude * (0.7 + 0.3 * sin(animationValue * pi));
      final scaledHeight = animatedAmplitude * size.height * (0.8 + rms * 2);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * barWidth,
            centerY - scaledHeight / 2,
            barWidth * 0.6,
            scaledHeight,
          ),
          const Radius.circular(8),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.animationValue != animationValue;
  }
}
