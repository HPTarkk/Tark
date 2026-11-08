import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/profile/avatar_catalog.dart';
import '../../../../core/profile/local_profile.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../report/presentation/widget/avatar_images.dart';
import 'usage_tips_scene_painter.dart';

/// One-time (ever) usage-tips sheet: practical suggestions for a better
/// ride, told as a tiny story about you on the road. Shown once per install;
/// see [SettingsRepository.usageTipsShown] for the persisted flag that
/// guards this.
///
/// [initialPage] exists for dev harnesses/screenshots; production always
/// opens at the first tip.
Future<void> showUsageTipsSheet(BuildContext context, {int initialPage = 0}) =>
    showModalBottomSheet<void>(
      context: context,
      routeSettings: const RouteSettings(name: 'UsageTipsSheet'),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (_) => UsageTipsSheet(initialPage: initialPage),
    );

/// The tips, told on one stage the way the report and rating stories are.
///
/// You ride along a road that rolls on as you swipe, and each tip is one
/// thing changing about your ride: a headset drops on and the wind noise
/// dissolves before your ears; a helmet lands, its visor slides down and
/// the strap clicks; a push-to-talk button gets struck out and you just
/// talk to the friend riding beside you; a phone rises with Tarkk's widget
/// on it, and one tap puts you back on the road.
///
/// The scene follows the finger: swiping crossfades one tip's props into
/// the next while the next one waits in its "about to happen" pose, and
/// when the carousel settles that tip plays its act. Tapping the scene
/// makes you jump. The page dots are tappable, and the one button hands
/// over from "Next" to "Got it" on the last tip.
///
/// Reduced motion keeps every state (each tip's props in place, the page
/// position, the hand-over) and drops the travel: no drops, hops, bobbing,
/// rolling road or ambient noise.
class UsageTipsSheet extends StatefulWidget {
  const UsageTipsSheet({this.initialPage = 0, super.key});

  final int initialPage;

  static const int tipCount = 4;

  @override
  State<UsageTipsSheet> createState() => _UsageTipsSheetState();
}

class _UsageTipsSheetState extends State<UsageTipsSheet>
    with TickerProviderStateMixin {
  late final PageController _pager = PageController(
    initialPage: widget.initialPage,
  );

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _arrive = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  late final AnimationController _hop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  late final Listenable _scene = Listenable.merge([
    _pager,
    _intro,
    _ambient,
    _arrive,
    _hop,
  ]);

  /// The tip the carousel last came to rest on; its act is [_arrive].
  late int _tip = widget.initialPage;

  /// The page the carousel is closest to right now, for the button and
  /// the words: it flips at the halfway point of a swipe.
  late int _page = widget.initialPage;

  bool _started = false;
  bool _thudPlayed = false;
  ui.Image? _youImage;

  bool get _reduced => AppMotion.reduced(context);
  bool get _isLast => _page == UsageTipsSheet.tipCount - 1;

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onScroll);
    _arrive.addListener(_onArrive);
    unawaited(_readFace());
  }

  /// Casts the story: you, as your own avatar (the mascot until you pick
  /// one), stickered on your helmet.
  Future<void> _readFace() async {
    final id = LocalProfile.avatarId ?? AvatarCatalog.defaultId;
    _youImage = AvatarImages.peek(id);
    if (_youImage != null) return;
    final image = await AvatarImages.load(id);
    if (mounted) setState(() => _youImage = image);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ambient.loopUnlessReduced(context, rest: 0.25);
    if (!_started) {
      _started = true;
      if (_reduced) {
        _intro.value = 1;
        _arrive.value = 1;
      } else {
        // You pop in first, then the first tip plays its act.
        unawaited(
          _intro.forward().then((_) {
            if (mounted) _play();
          }),
        );
      }
    }
  }

  @override
  void dispose() {
    _pager.dispose();
    _intro.dispose();
    _ambient.dispose();
    _arrive.dispose();
    _hop.dispose();
    super.dispose();
  }

  // ── Story beats ──────────────────────────────────────────────────────────

  /// Plays the settled tip's act from the top.
  void _play() {
    _thudPlayed = false;
    if (_reduced) {
      _arrive.value = 1;
    } else {
      unawaited(_arrive.forward(from: 0));
    }
  }

  void _onScroll() {
    if (!_pager.hasClients || !_pager.position.haveDimensions) return;
    final page = _pager.page ?? _tip.toDouble();
    final nearest = page.round().clamp(0, UsageTipsSheet.tipCount - 1);
    if (nearest != _page) setState(() => _page = nearest);
    // Settled on a new tip: its act begins.
    if ((page - nearest).abs() < 0.001 && nearest != _tip) {
      HapticFeedback.selectionClick();
      setState(() => _tip = nearest);
      _play();
    }
  }

  /// The headset and the helmet land with a little thud you can feel.
  void _onArrive() {
    if (_thudPlayed || _tip > 1 || _reduced) return;
    final landsAt = _tip == 0 ? 0.09 : 0.083;
    if (_arrive.value >= landsAt) {
      _thudPlayed = true;
      HapticFeedback.lightImpact();
    }
  }

  void _goTo(int page) {
    if (!_pager.hasClients) return;
    final distance = (page - (_pager.page ?? _tip)).abs();
    unawaited(
      _pager.animateToPage(
        page,
        duration: Duration(
          milliseconds: (380 + 90 * math.max(0.0, distance - 1)).round(),
        ),
        curve: AppMotion.easeInOut,
      ),
    );
  }

  void _advance() {
    if (_isLast) {
      Navigator.of(context).maybePop();
    } else {
      _goTo(_page + 1);
    }
  }

  void _tapScene(Offset local, Size size) {
    final at = UsageTipsScenePainter.toStage(local, size);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final you = UsageTipsScenePainter.youAtLtr;
    final youAt = rtl
        ? Offset(UsageTipsScenePainter.stage.width - you.dx, you.dy)
        : you;
    if ((at - youAt).distance > 56 || _reduced) return;
    HapticFeedback.selectionClick();
    unawaited(_hop.forward(from: 0));
  }

  // ── Frame ────────────────────────────────────────────────────────────────

  UsageTipsFrame _frame(BuildContext context) {
    var page = _tip.toDouble();
    if (_pager.hasClients && _pager.position.haveDimensions) {
      page = _pager.page ?? page;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return UsageTipsFrame(
      youIn: Curves.easeOutBack.transform(_intro.value),
      page: page.clamp(0.0, UsageTipsSheet.tipCount - 1.0),
      tip: _tip,
      arrive: _arrive.value,
      hop: _hop.isAnimating ? _hop.value : 0,
      ambient: _ambient.value,
      rtl: Directionality.of(context) == TextDirection.rtl,
      youColor: AppColors.amber,
      friendColor: const Color(0xFF4FB3BF),
      ink: const Color(0xFF1B1F24),
      paper: const Color(0xFFFFF6EC),
      road: AppColors.border.withValues(alpha: dark ? 1 : 0.9),
      danger: AppColors.red,
      youImage: _youImage,
    );
  }

  // ── Layout ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final tips = [
      (s.usage_tips_1_title, s.usage_tips_1_body),
      (s.usage_tips_2_title, s.usage_tips_2_body),
      (s.usage_tips_3_title, s.usage_tips_3_body),
      (s.usage_tips_4_title, s.usage_tips_4_body),
    ];

    return SheetShell(
      topFraction: 0.06,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Eyebrow(text: s.usage_tips_title, tracked: !isFa),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: AspectRatio(
                aspectRatio:
                    UsageTipsScenePainter.stage.width /
                    UsageTipsScenePainter.stage.height,
                child: LayoutBuilder(
                  builder: (context, box) => Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _scene,
                          builder: (context, _) => CustomPaint(
                            key: const Key('usage-tips-scene'),
                            painter: UsageTipsScenePainter(_frame(context)),
                          ),
                        ),
                      ),
                      // The swipe: an invisible carousel over the stage, so
                      // the scene follows the finger with real page physics
                      // (and runs the other way in Persian on its own).
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTapUp: (d) => _tapScene(d.localPosition, box.biggest),
                        child: PageView.builder(
                          key: const Key('usage-tips-pager'),
                          controller: _pager,
                          itemCount: UsageTipsSheet.tipCount,
                          itemBuilder: (_, _) => const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            _TipWords(controller: _pager, tips: tips, initial: _tip),
            const SizedBox(height: 10),
            Center(
              child: _SignalDots(
                controller: _pager,
                count: UsageTipsSheet.tipCount,
                onPick: _goTo,
              ),
            ),
            const SizedBox(height: 12),
            _AdvanceButton(
              label: _isLast ? s.usage_tips_dismiss : s.usage_tips_next,
              last: _isLast,
              onTap: _advance,
            ),
            const SizedBox(height: 2),
            // A quiet way out on every tip but the last, where the main
            // button already is the way out. It keeps its room either way,
            // so the sheet never changes height under your thumb.
            IgnorePointer(
              ignoring: _isLast,
              child: ExcludeSemantics(
                excluding: _isLast,
                child: AnimatedOpacity(
                  duration: AppMotion.card,
                  curve: AppMotion.easeOut,
                  opacity: _isLast ? 0 : 1,
                  child: TextButton(
                    key: const Key('usage-tips-skip'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(
                      s.usage_tips_skip,
                      style: const TextStyle(fontWeight: FontWeight.w700),
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

/// The sheet's quiet heading: a small amber line with a twinkle beside it.
class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.text, required this.tracked});

  final String text;

  /// Latin script is tracked; Persian is a connected script, and tracking
  /// it apart breaks the joins.
  final bool tracked;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.amber),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          tracked ? text.toUpperCase() : text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: tracked ? 11.5 : 13,
            fontWeight: FontWeight.w800,
            letterSpacing: tracked ? 1.6 : 0,
          ),
        ),
      ),
    ],
  );
}

/// Signed distance of page [index] from the carousel's position: 0 when
/// centred, ±1 a full page away. Before the controller attaches (the first
/// frame), falls back to [initial] so only that page reads as centred.
double _pageDelta(PageController controller, int index, int initial) {
  var page = initial.toDouble();
  if (controller.hasClients && controller.position.haveDimensions) {
    page = controller.page ?? page;
  }
  return (page - index).clamp(-1.0, 1.0);
}

/// Each tip's words, driven by the swipe itself: the incoming tip's words
/// rise in as the outgoing ones lift away, both fading, tracking the finger.
/// All four are always laid out in one stack, so the area is as tall as the
/// longest tip from the first frame and nothing clips or jumps.
class _TipWords extends StatelessWidget {
  const _TipWords({
    required this.controller,
    required this.tips,
    required this.initial,
  });

  final PageController controller;
  final List<(String, String)> tips;
  final int initial;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Stack(
        alignment: Alignment.topCenter,
        children: [
          for (var i = 0; i < tips.length; i++)
            _words(
              _pageDelta(controller, i, initial),
              tips[i],
              reduced: reduced,
            ),
        ],
      ),
    );
  }

  Widget _words(double delta, (String, String) tip, {required bool reduced}) {
    final visibility = (1 - delta.abs()).clamp(0.0, 1.0);
    // Each side only shows past the halfway mark, so mid-swipe never reads
    // as two texts mushed together: the old words are gone by the time the
    // new ones start to rise.
    final opacity = AppMotion.easeOut.transform(
      ((visibility - 0.45) / 0.55).clamp(0.0, 1.0),
    );
    final (title, body) = tip;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 19,
            fontWeight: FontWeight.w900,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 13.5,
            height: 1.55,
          ),
        ),
      ],
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        excluding: visibility < 0.5,
        child: Opacity(
          opacity: opacity,
          child: reduced
              ? content
              : Transform.translate(
                  // Arriving words rise from below; leaving ones lift away.
                  offset: Offset(0, delta * 22),
                  child: content,
                ),
        ),
      ),
    );
  }
}

/// Page indicator styled as a radio carrier. Idle pages are faint channel
/// ticks; the active one is an amber pill that stretches worm-like toward
/// the next tick as you swipe (the head races ahead, the tail catches up)
/// and, once settled, sits "transmitting": looping ripple rings that mute
/// while a drag is in flight. Tapping a tick tunes straight to that tip.
class _SignalDots extends StatefulWidget {
  const _SignalDots({
    required this.controller,
    required this.count,
    required this.onPick,
  });

  final PageController controller;
  final int count;
  final ValueChanged<int> onPick;

  @override
  State<_SignalDots> createState() => _SignalDotsState();
}

class _SignalDotsState extends State<_SignalDots>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pulse.loopUnlessReduced(context, rest: 0.35);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Size get _size =>
      Size((widget.count - 1) * _SignalDotsPainter.spacing + 64, 32);

  void _onTap(Offset local, bool rtl) {
    final size = _size;
    final start =
        (size.width - (widget.count - 1) * _SignalDotsPainter.spacing) / 2;
    var x = local.dx;
    if (rtl) x = size.width - x;
    final i = ((x - start) / _SignalDotsPainter.spacing).round();
    if (i < 0 || i >= widget.count) return;
    widget.onPick(i);
  }

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _onTap(d.localPosition, rtl),
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.controller, _pulse]),
            builder: (context, _) {
              var page = widget.controller.initialPage.toDouble();
              if (widget.controller.hasClients &&
                  widget.controller.position.haveDimensions) {
                page = widget.controller.page ?? page;
              }
              return CustomPaint(
                key: const Key('usage-tips-dots'),
                size: _size,
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
        ),
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
    final head = _lerp(
      _dotX(base, size),
      _dotX(next, size),
      Curves.easeOutCubic.transform(f),
    );
    final tail = _lerp(
      _dotX(base, size),
      _dotX(next, size),
      Curves.easeInCubic.transform(f),
    );
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
      final center = Offset(
        f < 0.5 ? _dotX(base, size) : _dotX(next, size),
        cy,
      );
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

/// The sheet's one button, from the first tip to the last.
///
/// It never swaps itself out. Until the last tip it is a quiet amber-tinted
/// "Next" whose arrow nudges toward the reading end now and then; on the
/// last tip it fills solid amber and hands its words over to "Got it", the
/// arrow turning into a check that draws itself in.
class _AdvanceButton extends StatefulWidget {
  const _AdvanceButton({
    required this.label,
    required this.last,
    required this.onTap,
  });

  final String label;
  final bool last;
  final VoidCallback onTap;

  @override
  State<_AdvanceButton> createState() => _AdvanceButtonState();
}

class _AdvanceButtonState extends State<_AdvanceButton>
    with TickerProviderStateMixin {
  late final AnimationController _nudge = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );
  late final AnimationController _check = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.last ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _nudge.loopUnlessReduced(context);
  }

  @override
  void didUpdateWidget(_AdvanceButton old) {
    super.didUpdateWidget(old);
    if (old.last == widget.last) return;
    if (AppMotion.reduced(context)) {
      _check.value = widget.last ? 1 : 0;
    } else if (widget.last) {
      unawaited(_check.forward(from: 0));
    } else {
      unawaited(_check.reverse());
    }
  }

  @override
  void dispose() {
    _nudge.dispose();
    _check.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.last;
    final fill = last
        ? AppColors.amber
        : Color.alphaBlend(
            AppColors.amber.withValues(alpha: 0.14),
            AppColors.card,
          );
    final ink = last ? AppColors.background : AppColors.amber;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: PressableScale(
        key: const Key('usage-tips-advance'),
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: fill),
          duration: AppMotion.sheet,
          curve: AppMotion.easeOut,
          builder: (context, fill, _) => TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: ink),
            duration: AppMotion.sheet,
            curve: AppMotion.easeOut,
            builder: (context, ink, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: AppColors.amber.withValues(alpha: last ? 0 : 0.55),
                  width: 1.4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.amber.withValues(alpha: last ? 0.3 : 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SizedBox(
                height: 52,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 360),
                        switchInCurve: const Interval(
                          0.45,
                          1,
                          curve: AppMotion.easeOut,
                        ),
                        switchOutCurve: const Interval(
                          0.45,
                          1,
                          curve: AppMotion.easeOut,
                        ),
                        transitionBuilder: HandOver.transition(
                          rise: 0.5,
                          lift: 0.4,
                        ),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.center,
                          children: [...previous, ?current],
                        ),
                        child: Text(
                          widget.label,
                          key: ValueKey(widget.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    AnimatedBuilder(
                      animation: Listenable.merge([_nudge, _check]),
                      builder: (context, _) => CustomPaint(
                        size: const Size(20, 20),
                        painter: _ArrowCheckPainter(
                          nudge: _nudge.value,
                          check: _check.value,
                          color: ink!,
                          rtl: rtl,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An arrow toward the reading end that nudges forward twice per loop, and
/// that folds into a check mark as [check] runs 0 → 1.
class _ArrowCheckPainter extends CustomPainter {
  _ArrowCheckPainter({
    required this.nudge,
    required this.check,
    required this.color,
    required this.rtl,
  });

  final double nudge;
  final double check;
  final Color color;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final c = AppMotion.easeOut.transform(check.clamp(0.0, 1.0));
    if (c < 1) {
      // Two quick forward taps, then a rest.
      final t = (nudge * 2) % 1;
      final push = t < 0.3 ? math.sin(math.pi * t / 0.3) * 3 : 0.0;
      final a = 1 - c;
      // Only the arrow points along the reading direction; a check mark
      // is never mirrored.
      canvas.save();
      if (rtl) canvas.scale(-1, 1);
      canvas.translate(push * a, 0);
      final arrow = Paint()
        ..color = color.withValues(alpha: color.a * a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawLine(const Offset(-7, 0), Offset(7 * a, 0), arrow);
      canvas.drawPath(
        Path()
          ..moveTo(1.5, -5.5)
          ..lineTo(7, 0)
          ..lineTo(1.5, 5.5),
        arrow,
      );
      canvas.restore();
    }
    if (c > 0) {
      const a = Offset(-6.5, 0.5);
      const m = Offset(-2, 5);
      const e = Offset(7, -5);
      final path = Path()..moveTo(a.dx, a.dy);
      if (c < 0.4) {
        final p = Offset.lerp(a, m, c / 0.4)!;
        path.lineTo(p.dx, p.dy);
      } else {
        path.lineTo(m.dx, m.dy);
        final p = Offset.lerp(m, e, (c - 0.4) / 0.6)!;
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArrowCheckPainter old) =>
      old.nudge != nudge ||
      old.check != check ||
      old.color != color ||
      old.rtl != rtl;
}
