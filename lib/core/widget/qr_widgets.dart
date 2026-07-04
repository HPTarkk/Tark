import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/app_colors.dart';

/// QR code presented like a transmission artifact: white tile with an amber
/// glow, radar-style corner brackets, and a slow scanline sweeping over it.
/// Shared by the host invite screen and the web guest's reply screen.
class GlowingQrCard extends StatefulWidget {
  final String data;
  final double size;

  const GlowingQrCard({super.key, required this.data, this.size = 250});

  @override
  State<GlowingQrCard> createState() => _GlowingQrCardState();
}

class _GlowingQrCardState extends State<GlowingQrCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = widget.size + 28;
    return SizedBox(
      width: inset + 26,
      height: inset + 26,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Corner brackets floating outside the tile.
          Positioned.fill(
            child: CustomPaint(
              painter: CornerBracketsPainter(
                color: AppColors.amber.withAlpha(190),
              ),
            ),
          ),
          Container(
            width: inset,
            height: inset,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppColors.amber.withAlpha(46),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  QrImageView(
                    data: widget.data,
                    version: QrVersions.auto,
                    size: widget.size,
                    gapless: true,
                  ),
                  // Scanline sweep.
                  AnimatedBuilder(
                    animation: _sweep,
                    builder: (context, _) {
                      final t = Curves.easeInOut.transform(_sweep.value);
                      return Positioned(
                        top: t * (widget.size - 26),
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Container(
                            height: 26,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  AppColors.amberDim.withAlpha(0),
                                  AppColors.amberDim.withAlpha(60),
                                  AppColors.amberDim.withAlpha(0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Four L-shaped viewfinder corners, used around QR tiles and camera scan
/// windows.
class CornerBracketsPainter extends CustomPainter {
  final Color color;
  final double length;
  final double stroke;
  final double radius;

  CornerBracketsPainter({
    required this.color,
    this.length = 26,
    this.stroke = 3,
    this.radius = 14,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;
    final l = length;
    final r = radius;
    final arc = Radius.circular(r);

    canvas.drawPath(
      Path()
        ..moveTo(l, 0)
        ..lineTo(r, 0)
        ..arcToPoint(Offset(0, r), radius: arc, clockwise: false)
        ..lineTo(0, l),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w - l, 0)
        ..lineTo(w - r, 0)
        ..arcToPoint(Offset(w, r), radius: arc)
        ..lineTo(w, l),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(0, h - l)
        ..lineTo(0, h - r)
        ..arcToPoint(Offset(r, h), radius: arc, clockwise: false)
        ..lineTo(l, h),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(w, h - l)
        ..lineTo(w, h - r)
        ..arcToPoint(Offset(w - r, h), radius: arc)
        ..lineTo(w - l, h),
      paint,
    );
  }

  @override
  bool shouldRepaint(CornerBracketsPainter old) =>
      old.color != color || old.length != length;
}

/// Numbered instruction row with the app's amber-ring index bullets.
class StepRow extends StatelessWidget {
  final int index;
  final IconData icon;
  final String text;

  const StepRow({
    super.key,
    required this.index,
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amber.withAlpha(28),
            border: Border.all(color: AppColors.amber.withAlpha(130)),
          ),
          child: Text(
            '$index',
            style: TextStyle(
              color: AppColors.amber,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
