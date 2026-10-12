import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../gen/assets.gen.dart';
import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import '../utils/extensions.dart';
import 'qr_brand_plan.dart';

/// QR code presented like a transmission artifact: white tile with an amber
/// glow, radar-style corner brackets, and a slow scanline sweeping over it.
/// Shared by every code Tarkk shows — invites, hotspot, reconnect, guests.
///
/// Every one carries the Tarkk mark in its centre. That is a design decision,
/// not decoration, and it is never traded away for length: [QrBrandPlan]
/// picks the error-correction level, the version and the exact size of the
/// knock-out so the mark always stays within half of what the code can
/// repair, however long the payload grows.
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
  );

  late QrBrandPlan _plan = QrBrandPlan.of(widget.data, size: widget.size);

  @override
  void didUpdateWidget(GlowingQrCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data || oldWidget.size != widget.size) {
      _plan = QrBrandPlan.of(widget.data, size: widget.size);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sweep.loopUnlessReduced(context, reverse: true);
  }

  Widget? _code;
  QrBrandPlan? _codePlan;
  String? _codeData;

  Widget _codeFor(QrBrandPlan plan) {
    if (_code == null ||
        _codeData != widget.data ||
        _codePlan?.version != plan.version ||
        _codePlan?.errorCorrectLevel != plan.errorCorrectLevel) {
      _codeData = widget.data;
      _codePlan = plan;
      _code = RepaintBoundary(
        child: QrImageView(
          data: widget.data,
          version: plan.version,
          errorCorrectionLevel: plan.errorCorrectLevel,
          size: plan.moduleCount.toDouble(),
          padding: EdgeInsets.zero,
          gapless: true,
        ),
      );
    }
    return _code!;
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inset = widget.size + 28;
    final plan = _plan;
    final code = plan.codeExtent(widget.size);
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
                  // A dense QR is thousands of tiny rects — painting it 60×/s
                  // under the moving scanline was the lag. The boundary
                  // rasterizes it once.
                  //
                  // Drawn at exactly the plan's module pitch: the code is
                  // painted one logical pixel per module and scaled up, so
                  // qr_flutter's half-pixel rounding never shrinks a module
                  // or pushes the code into its quiet zone. The same instance
                  // is reused while only the size changes, so a card growing
                  // under an animation re-rasterizes a cached picture rather
                  // than re-encoding the code every frame.
                  Center(
                    child: SizedBox.square(
                      dimension: code,
                      child: FittedBox(child: _codeFor(plan)),
                    ),
                  ),
                  // Drawn as an overlay rather than through qr_flutter's
                  // embeddedImage so the knock-out lands on whole modules and
                  // the mark keeps its white quiet ring — without that gap
                  // the dark tile's edge reads as modules and decoders hunt
                  // for structure that isn't there.
                  if (plan.branded)
                    Positioned.fill(
                      child: Center(
                        child: RepaintBoundary(
                          child: _BrandMark(
                            key: const Key('qr-brand-mark'),
                            size: plan.markExtent(widget.size),
                          ),
                        ),
                      ),
                    ),
                  // Scanline sweep: its own layer, so animating it only
                  // moves a small cached strip around — no QR repaints.
                  AnimatedBuilder(
                    animation: _sweep,
                    builder: (context, child) {
                      final t = Curves.easeInOut.transform(_sweep.value);
                      return Positioned(
                        top: t * (widget.size - 26),
                        left: 0,
                        right: 0,
                        child: child!,
                      );
                    },
                    child: IgnorePointer(
                      child: RepaintBoundary(
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
                    ),
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

/// The Tarkk mark on its white quiet ring, sized to sit in a QR's centre.
class _BrandMark extends StatelessWidget {
  final double size;

  const _BrandMark({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.13),
      decoration: BoxDecoration(
        // Matches the card behind the code, so the ring reads as a punched
        // hole rather than a sticker sitting on top.
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.asset(
          Assets.icon.icon.path,
          filterQuality: FilterQuality.medium,
        ),
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
///
/// The bullet, the icon and the first line of text share one optical centre
/// line — the bullet's middle. The icon and the text are deliberately *not*
/// centred against the row: a step that wraps onto two lines would drag them
/// down to the middle of the paragraph, away from the line they label. So
/// each gets a top offset instead, worked out from the font rather than
/// nudged by eye:
///
/// * the icon's box centre goes on the bullet's centre;
/// * the text's first line is placed so its *optical* centre lands there —
///   the middle of the x-height for Latin, and the middle of the lower body
///   for Persian, whose letters sit on the baseline and reach well below
///   Latin's x-height centre. The same box centred would put Persian text a
///   good pixel and a half higher than English next to the same icon.
///
/// The offsets follow the text scale: once enlarged text's centre falls
/// below the bullet's, the bullet and icon move down to it instead.
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

  static const double _bullet = 24;
  static const double _icon = 16;
  static const double _fontSize = 12.5;
  static const double _lineHeight = 1.5;

  // Vazirmatn's vertical metrics, in font units (2048 per em): the typo
  // ascender and descender Flutter lays lines out with, and the OS/2
  // x-height. Vazirmatn is the app's font for both languages.
  static const double _ascent = 2100;
  static const double _descent = 1100;
  static const double _xHeight = 1082;
  static const double _unitsPerEm = 2048;

  /// Where Persian's optical body centres, above the baseline, in ems. The
  /// teeth and bowls of the common letters (ب س ن ی ه) occupy roughly the
  /// lowest third of an em; measured from Vazirmatn renders of the real step
  /// strings, the dense band's middle sits 0.175 em up.
  static const double _persianBody = 0.175;

  static final _arabicScript = RegExp(r'[؀-ۿݐ-ݿ]');

  /// Distance from the top of the first line box to its optical centre, for
  /// a font size of [em] logical pixels.
  static double opticalCentre(String text, double em) {
    final line = em * _lineHeight;
    // Flutter's default (proportional) leading splits a line's height in the
    // font's ascent:descent ratio, so the baseline lands here.
    final baseline = line * _ascent / (_ascent + _descent);
    final rise = _arabicScript.hasMatch(text)
        ? _persianBody * em
        : _xHeight / _unitsPerEm / 2 * em;
    return baseline - rise;
  }

  @override
  Widget build(BuildContext context) {
    final em = MediaQuery.textScalerOf(context).scale(_fontSize);
    final textCentre = opticalCentre(text, em);
    final axis = textCentre > _bullet / 2 ? textCentre : _bullet / 2;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: axis - _bullet / 2),
          child: Container(
            width: _bullet,
            height: _bullet,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.amber.withAlpha(28),
              border: Border.all(color: AppColors.amber.withAlpha(130)),
            ),
            child: Text(
              index.localized(context),
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Padding(
          padding: EdgeInsets.only(top: axis - _icon / 2),
          child: Icon(icon, size: _icon, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: axis - textCentre),
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: _fontSize,
                height: _lineHeight,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
