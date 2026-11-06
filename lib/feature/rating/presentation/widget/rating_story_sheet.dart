import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/profile/avatar_catalog.dart';
import '../../../../core/profile/local_profile.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/copy_chip.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../../report/presentation/widget/avatar_images.dart';
import '../../../update/api/update_api.dart';
import '../../data/bazaar_review_launcher.dart';
import '../../domain/rating_prompt.dart';
import 'rating_scene_painter.dart';

/// Opens the rating story.
///
/// [launcher] and [prompt] are seams for tests; the app opens Bazaar through
/// `StoreHandler` and keeps the bookkeeping in the shared [RatingPrompt].
Future<void> showRatingStory(
  BuildContext context, {
  RatingPrompt? prompt,
  Future<ReviewOutcome> Function()? launcher,
}) => showModalBottomSheet<void>(
  context: context,
  routeSettings: const RouteSettings(name: 'RatingStorySheet'),
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  barrierColor: Colors.black.withValues(alpha: 0.62),
  builder: (_) => RatingStorySheet(
    prompt: prompt ?? RatingPrompt.registered,
    launcher: launcher ?? const BazaarReviewLauncher().open,
  ),
);

/// Asks for a rating on arriving home from a good ride, if [RatingPrompt]'s
/// rules allow it right now. Call once Home has finished arriving.
Future<void> maybeAskForRating(
  BuildContext context, {
  RatingPrompt? prompt,
  Future<ReviewOutcome> Function()? launcher,
  Duration settle = const Duration(milliseconds: 650),
}) async {
  final rules = prompt ?? RatingPrompt.registered;
  if (rules == null || !rules.takeAskMoment()) return;
  if (UpdateGate.promptShowing) return;
  // A breath after Home settles, so the ask reads as its own moment.
  await Future<void>.delayed(settle);
  if (!context.mounted) return;
  if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
  if (UpdateGate.promptShowing) return;
  await rules.recordAsked();
  if (!context.mounted) return;
  await showRatingStory(context, prompt: rules, launcher: launcher);
}

enum _Phase { intro, ask, launching, away, thanks, failed }

/// Asking for a rating, told as a tiny story instead of a dialog.
///
/// You and a friend ride side by side, talking over Tarkk. The radio waves
/// between your helmets throw off five stars that settle above you and
/// twinkle: the rides you have shared. Tapping either of you makes them hop.
/// Rating gathers the five stars into one, which shoots off as a comet; that
/// is Tarkk handing you over to Cafe Bazaar, where the actual rating happens.
/// When you come back, the star falls home and bursts into thanks.
///
/// Nothing pretends: the stars are not a rating control (all five are always
/// lit), and the comet leaves exactly when Bazaar opens. Tarkk never sees the
/// rating, and the thanks never claims it was posted.
///
/// Reduced motion keeps every state (the stars, the hand-over, the thanks)
/// and drops the travel.
class RatingStorySheet extends StatefulWidget {
  const RatingStorySheet({
    required this.prompt,
    required this.launcher,
    super.key,
  });

  final RatingPrompt? prompt;
  final Future<ReviewOutcome> Function() launcher;

  @override
  State<RatingStorySheet> createState() => _RatingStorySheetState();
}

class _RatingStorySheetState extends State<RatingStorySheet>
    with TickerProviderStateMixin {
  static const _gatherSpring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 14,
  );
  static const _moodSpring = SpringDescription(
    mass: 1,
    stiffness: 120,
    damping: 15,
  );

  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2300),
  );
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final AnimationController _gather = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _launch = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _home = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _mood = AnimationController.unbounded(
    vsync: this,
    value: 0.6,
  );
  late final AnimationController _youHop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );
  late final AnimationController _friendHop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 820),
  );

  late final Listenable _scene = Listenable.merge([
    _intro,
    _ambient,
    _gather,
    _launch,
    _home,
    _mood,
    _youHop,
    _friendHop,
  ]);

  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onResume: _onResume,
  );

  _Phase _phase = _Phase.intro;
  bool _started = false;
  bool _burstQueued = false;
  ui.Image? _youImage;

  bool get _reduced => AppMotion.reduced(context);

  @override
  void initState() {
    super.initState();
    _lifecycle; // Starts listening.
    _intro.addListener(_onIntro);
    _home.addListener(_onHome);
    unawaited(_readFace());
  }

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
    _ambient.loopUnlessReduced(context);
    if (!_started) {
      _started = true;
      if (_reduced) {
        _phase = _Phase.ask;
        _intro.value = 1;
      } else {
        _intro.forward();
      }
    }
  }

  void _onIntro() {
    if (_phase == _Phase.intro && _intro.value >= 0.72) {
      setState(() => _phase = _Phase.ask);
    }
  }

  /// At the burst, the five stars fly back out of the big one to their arc.
  void _onHome() {
    if (_burstQueued && _home.value >= 0.35) {
      _burstQueued = false;
      HapticFeedback.mediumImpact();
      _springTo(_gather, 0, _gatherSpring);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _intro.dispose();
    _ambient.dispose();
    _gather.dispose();
    _launch.dispose();
    _home.dispose();
    _mood.dispose();
    _youHop.dispose();
    _friendHop.dispose();
    super.dispose();
  }

  // ── Story beats ──────────────────────────────────────────────────────────

  Future<void> _rate() async {
    if (_phase != _Phase.ask && _phase != _Phase.failed) return;
    HapticFeedback.mediumImpact();
    final retry = _phase == _Phase.failed;
    setState(() => _phase = _Phase.launching);
    if (!_reduced) {
      if (retry) _launch.value = 0;
      // The stars swirl into one (a spring, so it overshoots and settles),
      // and the big star takes off the moment it has formed.
      _springTo(_gather, 1, _gatherSpring);
      await Future<void>.delayed(const Duration(milliseconds: 520));
      if (!mounted) return;
      HapticFeedback.lightImpact();
      await _launch.forward(from: 0);
    } else {
      _gather.value = 1;
      _launch.value = 1;
    }
    if (!mounted) return;
    final outcome = await widget.launcher();
    if (!mounted) return;
    if (outcome == ReviewOutcome.none) {
      // The star comes back to the arc, a little deflated.
      _launch.value = 0;
      _springTo(_gather, 0, _gatherSpring);
      _springTo(_mood, 0.1, _moodSpring);
      setState(() => _phase = _Phase.failed);
      return;
    }
    unawaited(widget.prompt?.recordOpened());
    setState(() => _phase = _Phase.away);
  }

  void _onResume() {
    if (_phase != _Phase.away || !mounted) return;
    _comeHome();
  }

  void _comeHome() {
    setState(() => _phase = _Phase.thanks);
    _springTo(_mood, 1, _moodSpring);
    if (_reduced) {
      _home.value = 1;
      _gather.value = 0;
      return;
    }
    _burstQueued = true;
    unawaited(_home.forward(from: 0));
  }

  void _tapScene(Offset local, Size size) {
    final at = RatingScenePainter.toStage(local, size);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Offset mirror(Offset p) =>
        rtl ? Offset(RatingScenePainter.stage.width - p.dx, p.dy) : p;
    const reach = RatingCartoonHit.reach;
    if ((at - mirror(RatingScenePainter.youAtLtr)).distance < reach) {
      _hop(_youHop);
    } else if ((at - mirror(RatingScenePainter.friendAtLtr)).distance < reach) {
      _hop(_friendHop);
    }
  }

  void _hop(AnimationController hop) {
    if (_reduced) return;
    HapticFeedback.selectionClick();
    unawaited(hop.forward(from: 0));
  }

  void _springTo(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    if (_reduced) {
      controller.value = target;
      return;
    }
    controller.animateWith(
      SpringSimulation(spring, controller.value, target, 0),
    );
  }

  // ── Frame ────────────────────────────────────────────────────────────────

  double _iv(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  RatingSceneFrame _frame(BuildContext context) {
    final t = _intro.value;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return RatingSceneFrame(
      youIn: Curves.easeOutBack.transform(_iv(t, 0, 0.24)),
      friendIn: Curves.easeOutBack.transform(_iv(t, 0.1, 0.34)),
      link: AppMotion.easeOut.transform(_iv(t, 0.26, 0.44)),
      wavePhase: _reduced ? 0.4 : (_ambient.value * 2) % 1,
      starBirth: _iv(t, 0.36, 1),
      gather: _gather.value,
      launch: _launch.value,
      homecoming: _home.value,
      youHop: _youHop.isAnimating ? _youHop.value : 0,
      friendHop: _friendHop.isAnimating ? _friendHop.value : 0,
      mood: _mood.value,
      ambient: _ambient.value,
      rtl: Directionality.of(context) == TextDirection.rtl,
      youColor: AppColors.amber,
      friendColor: const Color(0xFF4FB3BF),
      gold: const Color(0xFFFFC53D),
      ink: const Color(0xFF1B1F24),
      road: AppColors.border.withValues(alpha: dark ? 1 : 0.9),
      sky: AppColors.textSecondary,
      youImage: _youImage,
    );
  }

  // ── Layout ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final (title, body) = switch (_phase) {
      _Phase.intro ||
      _Phase.ask ||
      _Phase.launching => (s.rating_ask_title, s.rating_ask_body),
      _Phase.away => (s.rating_away_title, s.rating_away_body),
      _Phase.thanks => (s.rating_thanks_title, s.rating_thanks_body),
      _Phase.failed => (s.rating_failed_title, s.rating_failed_body),
    };
    final headlineKey = switch (_phase) {
      _Phase.intro || _Phase.ask || _Phase.launching => _Phase.ask,
      final phase => phase,
    };

    return SheetShell(
      topFraction: 0.06,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              image: true,
              label: s.rating_scene_label,
              child: ExcludeSemantics(
                child: AspectRatio(
                  aspectRatio:
                      RatingScenePainter.stage.width /
                      RatingScenePainter.stage.height,
                  child: LayoutBuilder(
                    builder: (context, box) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => _tapScene(d.localPosition, box.biggest),
                      child: RepaintBoundary(
                        child: AnimatedBuilder(
                          animation: _scene,
                          builder: (context, _) => CustomPaint(
                            key: const Key('rating-scene'),
                            painter: RatingScenePainter(_frame(context)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: AppMotion.sheet,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: HandOver.transition(),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: Column(
                key: ValueKey(headlineKey),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
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
              ),
            ),
            const SizedBox(height: 16),
            AnimatedSize(
              duration: AppMotion.sheet,
              curve: AppMotion.drawer,
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: AppMotion.sheet,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.leaving,
                transitionBuilder: HandOver.transition(),
                child: _controls(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    final s = context.getString;
    final close = TextButton(
      key: const Key('rating-not-now'),
      onPressed: _phase == _Phase.launching
          ? null
          : () => Navigator.of(context).maybePop(),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(
        _phase == _Phase.failed ? s.rating_close : s.rating_not_now,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
    switch (_phase) {
      case _Phase.intro:
        return const SizedBox(key: ValueKey('intro'), height: 112);
      case _Phase.ask:
      case _Phase.launching:
        return Column(
          key: const ValueKey('ask'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            StaggeredEntrance(
              builder: (context, children) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
              children: [
                _RateButton(
                  key: const Key('rating-rate'),
                  label: s.rating_rate,
                  onTap: _phase == _Phase.launching ? null : _rate,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    s.rating_rate_hint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                Padding(padding: const EdgeInsets.only(top: 4), child: close),
              ],
            ),
          ],
        );
      case _Phase.away:
        return Column(
          key: const ValueKey('away'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _WaitingDots(),
            const SizedBox(height: 10),
            TextButton(
              key: const Key('rating-back'),
              onPressed: _comeHome,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: Text(
                s.rating_back,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        );
      case _Phase.thanks:
        return Column(
          key: const ValueKey('thanks'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _PrimaryButton(
              key: const Key('rating-done'),
              label: s.rating_done,
              icon: Icons.favorite_rounded,
              color: AppColors.green,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ],
        );
      case _Phase.failed:
        return Column(
          key: const ValueKey('failed'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: CopyChip(
                key: const Key('rating-copy'),
                text: BazaarReviewLauncher.webListing.toString(),
                label: s.rating_copy_link,
                copiedLabel: s.rating_copied,
              ),
            ),
            const SizedBox(height: 14),
            _PrimaryButton(
              key: const Key('rating-retry'),
              label: s.rating_try_again,
              icon: Icons.refresh_rounded,
              color: AppColors.amber,
              onTap: _rate,
            ),
            const SizedBox(height: 4),
            close,
          ],
        );
    }
  }
}

/// How close to a rider's face a tap must land to make them hop, in stage
/// units.
abstract final class RatingCartoonHit {
  static const double reach = 48;
}

/// The primary action: amber, with five tiny stars that ripple across it on
/// a loop, a quiet "this is the one" without shouting.
class _RateButton extends StatefulWidget {
  const _RateButton({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_RateButton> createState() => _RateButtonState();
}

class _RateButtonState extends State<_RateButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.5);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = AppColors.amber;
    final onTap = widget.onTap;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: widget.label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedOpacity(
          duration: AppMotion.chip,
          opacity: onTap == null ? 0.55 : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _loop,
                    builder: (context, _) => CustomPaint(
                      size: const Size(46, 14),
                      painter: _StarRipplePainter(
                        _loop.value,
                        AppColors.background,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.background,
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StarRipplePainter extends CustomPainter {
  _StarRipplePainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 5;
    final step = size.width / n;
    for (var i = 0; i < n; i++) {
      // A wave of "lighting up" runs across the five, then rests.
      final phase = (t * 1.6 - i * 0.12).clamp(0.0, 1.0);
      final lift = math.sin(phase * math.pi);
      final c = Offset(step * (i + 0.5), size.height / 2 - 2.5 * lift);
      final r = 4.6 * (1 + 0.28 * lift);
      final path = Path();
      for (var k = 0; k < 10; k++) {
        final a = -math.pi / 2 + k * math.pi / 5;
        final len = k.isEven ? r : r * 0.48;
        final p = c + Offset(math.cos(a) * len, math.sin(a) * len);
        k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path..close(),
        Paint()..color = color.withValues(alpha: 0.75 + 0.25 * lift),
      );
    }
  }

  @override
  bool shouldRepaint(_StarRipplePainter old) =>
      old.t != t || old.color != color;
}

/// Three dots that hop in turn while Bazaar has the stage.
class _WaitingDots extends StatefulWidget {
  const _WaitingDots();

  @override
  State<_WaitingDots> createState() => _WaitingDotsState();
}

class _WaitingDotsState extends State<_WaitingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop.loopUnlessReduced(context, rest: 0.25);
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Transform.translate(
              offset: Offset(
                0,
                -5 *
                    math.max(
                      0,
                      math.sin((_loop.value - i * 0.15) * math.pi * 2),
                    ),
              ),
              child: Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    excludeSemantics: true,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.24),
              blurRadius: 16,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
