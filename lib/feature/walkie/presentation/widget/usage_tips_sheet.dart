import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/animations/anc_headset_loop_animation.dart';
import '../../../../core/widget/animations/anc_headset_loop_animation_light.dart';
import '../../../../core/widget/animations/helmet_loop_animation.dart';
import '../../../../core/widget/animations/helmet_loop_animation_light.dart';
import '../../../../core/widget/animations/mic_loop_animation.dart';
import '../../../../core/widget/animations/mic_loop_animation_light.dart';

class _Tip {
  final Widget asset;
  final Widget lightAsset;
  final String title;
  final String body;

  const _Tip({required this.asset, required this.lightAsset, required this.title, required this.body});
}

/// One-time (ever) usage-tips bottom sheet — practical suggestions for a
/// better riding experience, each paired with a small looping animation
/// (hand-authored Lottie for the first two, a custom-painted Flutter widget
/// for the third). Shown once per install; see
/// [SettingsRepository.usageTipsShown] for the persisted flag that guards
/// this.
///
/// [initialPage] exists for dev harnesses/screenshots; production always
/// opens at the first tip.
Future<void> showUsageTipsSheet(BuildContext context, {int initialPage = 0}) {
  final s = context.getString;
  final tips = [
    _Tip(
      asset: AncHeadsetLoopAnimation(),
      lightAsset: AncHeadsetLoopAnimationLight(),
      title: s.usage_tips_1_title,
      body: s.usage_tips_1_body,
    ),
    _Tip(
      asset: HelmetLoopAnimation(),
      lightAsset: HelmetLoopAnimationLight(),
      title: s.usage_tips_2_title,
      body: s.usage_tips_2_body,
    ),
    _Tip(
      asset: const MicLoopAnimation(),
      lightAsset: const MicLoopAnimationLight(),
      title: s.usage_tips_3_title,
      body: s.usage_tips_3_body,
    ),
  ];

  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => _UsageTipsSheet(tips: tips, initialPage: initialPage),
  );
}

class _UsageTipsSheet extends StatefulWidget {
  final List<_Tip> tips;
  final int initialPage;

  const _UsageTipsSheet({required this.tips, this.initialPage = 0});

  @override
  State<_UsageTipsSheet> createState() => _UsageTipsSheetState();
}

class _UsageTipsSheetState extends State<_UsageTipsSheet> {
  late final _controller = PageController(initialPage: widget.initialPage);
  late int _page = widget.initialPage;

  bool get _isLastPage => _page == widget.tips.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _advance() {
    if (_isLastPage) {
      Navigator.of(context).pop();
    } else {
      _controller.nextPage(duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // Persian is a connected script — tracking it apart breaks the joins.
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final isDark = Theme.brightnessOf(context) == Brightness.dark;
    // Only the artwork carousel has a fixed height; the text below it sizes
    // to its own content (a Stack of all three tips), so descriptions can
    // never be clipped no matter the screen.
    final artHeight = (MediaQuery.sizeOf(context).height * 0.30).clamp(180.0, 270.0);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: AppColors.amber.withAlpha(90)),
          boxShadow: [BoxShadow(color: AppColors.amber.withAlpha(30), blurRadius: 40, spreadRadius: -6)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.tips_and_updates_rounded, size: 17, color: AppColors.amber),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    s.usage_tips_title,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: artHeight,
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.tips.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _ParallaxArt(
                  index: i,
                  controller: _controller,
                  child: isDark ? widget.tips[i].asset : widget.tips[i].lightAsset,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _TextConveyor(controller: _controller, tips: widget.tips),
            const SizedBox(height: 8),
            _SignalDots(controller: _controller, count: widget.tips.length),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: _advance,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _isLastPage ? AppColors.amber : AppColors.amber.withAlpha(25),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.amber.withAlpha(140), width: 1.5),
                  boxShadow: _isLastPage
                      ? [BoxShadow(color: AppColors.amber.withAlpha(90), blurRadius: 18, spreadRadius: -2)]
                      : null,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    _isLastPage ? s.usage_tips_dismiss : s.usage_tips_next,
                    key: ValueKey(_isLastPage),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isLastPage ? AppColors.background : AppColors.amber,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: isFa ? 0 : 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Signed page-scroll offset of page [index]: 0 when centered, ±1 when a
/// full page away. Before the controller attaches (first frame), falls back
/// to the initial page so only that page's content reads as centered —
/// a plain 0 here would render every tip stacked on top of each other.
double _pageDelta(PageController controller, int index) {
  double page = controller.initialPage.toDouble();
  if (controller.hasClients && controller.position.haveDimensions) {
    page = controller.page ?? page;
  }
  return (page - index).clamp(-1.0, 1.0);
}

/// The artwork floats directly on the card (the loop animations paint no
/// background of their own) and lags behind its page's travel during a swipe
/// — classic parallax depth. Scaled up slightly to eat the generous margins
/// built into the 800x800 drawings; the PageView clips any spill.
class _ParallaxArt extends StatelessWidget {
  final int index;
  final PageController controller;
  final Widget child;

  const _ParallaxArt({required this.index, required this.controller, required this.child});

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, art) {
        final delta = _pageDelta(controller, index);
        return Transform.translate(
          // Mirrored in RTL where pages travel the other way.
          offset: Offset((rtl ? -1 : 1) * delta * 80, 0),
          child: art,
        );
      },
      child: Center(child: Transform.scale(scale: 1.2, child: child)),
    );
  }
}

/// The tip texts live outside the horizontal swipe: as the carousel moves,
/// the incoming tip's text rises from below while the outgoing one floats up
/// and away (reversed when swiping back), both fading — driven directly by
/// the drag position, so it tracks the finger. A plain Stack of all three
/// texts keeps the area sized to the tallest tip, so nothing can clip.
class _TextConveyor extends StatelessWidget {
  final PageController controller;
  final List<_Tip> tips;

  const _TextConveyor({required this.controller, required this.tips});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Stack(
        alignment: Alignment.topCenter,
        children: [
          for (var i = 0; i < tips.length; i++)
            _conveyorItem(_pageDelta(controller, i), tips[i]),
        ],
      ),
    );
  }

  Widget _conveyorItem(double delta, _Tip tip) {
    final visibility = (1 - delta.abs()).clamp(0.0, 1.0);
    return Opacity(
      // Ease-in on visibility keeps mid-swipe from reading as two texts
      // mushed together: each side stays faint until it's nearly settled.
      opacity: Curves.easeIn.transform(visibility),
      child: Transform.translate(
        offset: Offset(0, -delta * 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tip.title,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textPrimary, fontSize: 15.5, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                tip.body,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5, height: 1.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page indicator styled as a radio carrier. Idle pages are faint channel
/// ticks; the active one is an amber pill that stretches worm-like toward
/// the next tick as you swipe (the head races ahead, the tail catches up)
/// and, once settled, sits "transmitting" — looping ripple rings that mute
/// while a drag is in flight.
class _SignalDots extends StatefulWidget {
  final PageController controller;
  final int count;

  const _SignalDots({required this.controller, required this.count});

  @override
  State<_SignalDots> createState() => _SignalDotsState();
}

class _SignalDotsState extends State<_SignalDots> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: Listenable.merge([widget.controller, _pulse]),
        builder: (context, _) {
          double page = widget.controller.initialPage.toDouble();
          if (widget.controller.hasClients && widget.controller.position.haveDimensions) {
            page = widget.controller.page ?? page;
          }
          return CustomPaint(
            size: Size((widget.count - 1) * _SignalDotsPainter.spacing + 64, 28),
            painter: _SignalDotsPainter(
              page: page.clamp(0.0, (widget.count - 1).toDouble()),
              pulse: _pulse.value,
              count: widget.count,
              rtl: rtl,
              carrier: AppColors.amber,
              idle: AppColors.border,
            ),
          );
        },
      ),
    );
  }
}

class _SignalDotsPainter extends CustomPainter {
  static const spacing = 24.0;

  final double page;
  final double pulse;
  final int count;
  final bool rtl;
  final Color carrier;
  final Color idle;

  _SignalDotsPainter({
    required this.page,
    required this.pulse,
    required this.count,
    required this.rtl,
    required this.carrier,
    required this.idle,
  });

  double _dotX(int i, Size size) {
    final x = (size.width - (count - 1) * spacing) / 2 + i * spacing;
    return rtl ? size.width - x : x;
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;

    final idlePaint = Paint()..color = idle;
    for (var i = 0; i < count; i++) {
      canvas.drawCircle(Offset(_dotX(i, size), cy), 2.5, idlePaint);
    }

    final base = page.floor().clamp(0, count - 1);
    final next = (base + 1).clamp(0, count - 1);
    final f = (page - base).clamp(0.0, 1.0);
    final head = _lerp(_dotX(base, size), _dotX(next, size), Curves.easeOutCubic.transform(f));
    final tail = _lerp(_dotX(base, size), _dotX(next, size), Curves.easeInCubic.transform(f));
    final pill = RRect.fromLTRBR(
      math.min(head, tail) - 9,
      cy - 3,
      math.max(head, tail) + 9,
      cy + 3,
      const Radius.circular(3),
    );
    canvas.drawRRect(
      pill.inflate(1.5),
      Paint()
        ..color = carrier.withAlpha(110)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(pill, Paint()..color = carrier);

    // Broadcast ripples around the resting dot; `settled` fades them out as
    // soon as the pill starts traveling and back in on arrival.
    final settled = (1 - math.min(f, 1 - f) * 2).clamp(0.0, 1.0);
    if (settled > 0.05) {
      final center = Offset(f < 0.5 ? _dotX(base, size) : _dotX(next, size), cy);
      for (var k = 0; k < 2; k++) {
        final phase = (pulse + k * 0.5) % 1.0;
        canvas.drawCircle(
          center,
          6.0 + phase * 8.0,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = carrier.withValues(alpha: (1 - phase) * 0.5 * settled),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignalDotsPainter old) =>
      old.page != page ||
      old.pulse != pulse ||
      old.count != count ||
      old.rtl != rtl ||
      old.carrier != carrier ||
      old.idle != idle;
}
