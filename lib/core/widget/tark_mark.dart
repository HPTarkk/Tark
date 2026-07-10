import 'dart:math';

import 'package:flutter/material.dart';

/// The TARK brand mark — two swept wing pieces forming a "T", split by a
/// diagonal gap — traced 1:1 from the vector logo (473x409 viewBox,
/// borderless). Pure vector (no image assets), so it stays crisp at any size
/// and costs nothing to load.
///
/// Sized like an [Icon]: the widget occupies a [size]-square box and the
/// glyph is fitted and centered inside it, so it survives tight parent
/// constraints (e.g. a fixed-size [Container]). [pulse] (0..1) drives the
/// gentle breathing scale used on the splash emblem; leave it at 0 for a
/// static mark. When [colorDim] is omitted the mark is filled solid with
/// [color] instead of the top-to-bottom brand gradient.
class TarkMark extends StatelessWidget {
  const TarkMark({
    super.key,
    required this.size,
    required this.color,
    Color? colorDim,
    this.pulse = 0,
  }) : colorDim = colorDim ?? color;

  final double size;
  final Color color;
  final Color colorDim;
  final double pulse;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: CustomPaint(
          size: Size.square(size),
          painter: _TarkMarkPainter(
            pulse: pulse,
            color: color,
            colorDim: colorDim,
          ),
        ),
      ),
    );
  }
}

class _TarkMarkPainter extends CustomPainter {
  final double pulse;
  final Color color;
  final Color colorDim;

  const _TarkMarkPainter({
    required this.pulse,
    required this.color,
    required this.colorDim,
  });

  // Two closed contours — left wing, right wing + stem — left unconnected on
  // purpose: the gap between them is the mark's diagonal accent.
  static final Path _shape = _buildShape();
  static final Rect _bounds = _shape.getBounds();

  static Path _buildShape() {
    final path = Path()
      ..moveTo(311.402, 0)
      ..lineTo(6.90249, 0)
      ..cubicTo(6.90249, 0, 1.40249, 0, 0.402494, 3.5)
      ..cubicTo(-0.597506, 7, 0.402711, 10.5, 1.90249, 12.5)
      ..cubicTo(3.40228, 14.5, 70.4025, 100.5, 70.4025, 100.5)
      ..cubicTo(70.4025, 100.5, 73.4025, 103.5, 75.4025, 105)
      ..cubicTo(77.4025, 106.5, 81.9025, 106.5, 81.9025, 106.5)
      ..lineTo(159.402, 106.5)
      ..cubicTo(159.402, 106.5, 168.402, 106.5, 172.902, 109)
      ..cubicTo(177.402, 111.5, 179.402, 118.5, 180.902, 119)
      ..cubicTo(182.402, 119.5, 311.402, 0, 311.402, 0)
      ..close();

    path.addPath(
      Path()
        ..moveTo(466.402, 0)
        ..lineTo(351.902, 0)
        ..lineTo(180.902, 159)
        ..lineTo(180.902, 340)
        ..cubicTo(180.902, 342, 181.9, 344.5, 183.4, 345.5)
        ..cubicTo(184.9, 346.5, 184.9, 346.5, 187.902, 348.5)
        ..cubicTo(190.905, 350.5, 277.905, 405, 281.402, 407)
        ..cubicTo(284.9, 409, 287.402, 409.5, 289.4, 408.5)
        ..cubicTo(291.398, 407.5, 291.9, 405.5, 291.902, 402)
        ..cubicTo(291.905, 398.5, 291.905, 123, 291.902, 116.5)
        ..cubicTo(291.9, 110, 297.4, 107.5, 297.4, 107.5)
        ..cubicTo(297.4, 107.5, 299.405, 106.5, 305.402, 106.5)
        ..lineTo(385.4, 106.5)
        ..cubicTo(385.979, 106.5, 396.4, 106, 397.577, 105.288)
        ..cubicTo(398.028, 105.016, 399.423, 103.977, 399.9, 103.5)
        ..cubicTo(400.9, 102.5, 405.9, 96.5, 405.9, 96.5)
        ..lineTo(472.902, 11.5)
        ..cubicTo(472.902, 11.5, 472.9, 6, 472.902, 5)
        ..cubicTo(472.905, 4, 472.9, 2.99999, 471.4, 1.49999)
        ..cubicTo(469.9, 0, 467.9, 0, 466.402, 0)
        ..close(),
      Offset.zero,
    );
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / _bounds.width, size.height / _bounds.height);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(1 + 0.02 * pulse);
    canvas.scale(scale * 0.92);
    canvas.translate(-_bounds.center.dx, -_bounds.center.dy);

    canvas.drawPath(
      _shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, colorDim],
        ).createShader(_bounds),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_TarkMarkPainter old) =>
      old.pulse != pulse || old.color != color || old.colorDim != colorDim;
}
