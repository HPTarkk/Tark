import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/app_localizations.dart';
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

  /// The quiet button's last words, kept while it fades out.
  String? _lastSecondary;
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
  //
  // The sheet never changes shape as the story moves on. Every phase's words
  // are laid out at once (only one showing), so the sheet is as tall as the
  // longest of them from the first frame. Below them sits one set of
  // controls for the whole story: one button that recolours and hands its
  // words over in place, one slot under it for the hint or the link, and one
  // quiet button that keeps its room while it fades. Nothing is swapped for
  // a second copy of itself, so nothing doubles up and nothing jumps.

  /// The phase whose words are showing: the intro already shows the ask.
  _Phase get _shown => switch (_phase) {
    _Phase.intro || _Phase.ask || _Phase.launching => _Phase.ask,
    final phase => phase,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final shown = _shown;
    const phases = [_Phase.ask, _Phase.away, _Phase.thanks, _Phase.failed];
    final controlsUp = _phase != _Phase.intro;

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
            Stack(
              alignment: Alignment.topCenter,
              children: [
                for (final phase in phases)
                  _Headline(
                    key: ValueKey('headline-${phase.name}'),
                    title: _title(s, phase),
                    body: _body(s, phase),
                    visible: phase == shown,
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _Arrival(visible: controlsUp, child: _controls(context)),
          ],
        ),
      ),
    );
  }

  String _title(AppLocalizations s, _Phase phase) => switch (phase) {
    _Phase.away => s.rating_away_title,
    _Phase.thanks => s.rating_thanks_title,
    _Phase.failed => s.rating_failed_title,
    _ => s.rating_ask_title,
  };

  String _body(AppLocalizations s, _Phase phase) => switch (phase) {
    _Phase.away => s.rating_away_body,
    _Phase.thanks => s.rating_thanks_body,
    _Phase.failed => s.rating_failed_body,
    _ => s.rating_ask_body,
  };

  Widget _controls(BuildContext context) {
    final s = context.getString;
    final phase = _shown;
    final launching = _phase == _Phase.launching;

    final (
      String label,
      _Glyph glyph,
      Color fill,
      Color ink,
      VoidCallback? onTap,
    ) = switch (phase) {
      _Phase.away => (
        s.rating_back,
        _Glyph.dots,
        Color.alphaBlend(
          AppColors.amber.withValues(alpha: 0.16),
          AppColors.card,
        ),
        AppColors.amber,
        _comeHome,
      ),
      _Phase.thanks => (
        s.rating_done,
        _Glyph.heart,
        AppColors.green,
        Colors.white,
        () => Navigator.of(context).maybePop(),
      ),
      _Phase.failed => (
        s.rating_try_again,
        _Glyph.retry,
        AppColors.amber,
        AppColors.background,
        _rate,
      ),
      _ => (
        s.rating_rate,
        _Glyph.stars,
        AppColors.amber,
        AppColors.background,
        launching || _phase == _Phase.intro ? null : _rate,
      ),
    };
    final buttonKey = switch (phase) {
      _ when _phase == _Phase.intro => null,
      _Phase.away => const Key('rating-back'),
      _Phase.thanks => const Key('rating-done'),
      _Phase.failed => const Key('rating-retry'),
      _ => const Key('rating-rate'),
    };

    final secondary = switch (phase) {
      _Phase.ask => s.rating_not_now,
      _Phase.failed => s.rating_close,
      _ => null,
    };
    if (secondary != null) _lastSecondary = secondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _MorphButton(
          labelKey: buttonKey,
          label: label,
          glyph: glyph,
          fill: fill,
          ink: ink,
          onTap: onTap,
        ),
        // One slot under the button: the hint while asking, the link when
        // nothing opened, and empty room otherwise. Both are always laid out,
        // so the slot is as tall as the taller of them in every phase.
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Stack(
            alignment: Alignment.center,
            children: [
              _Fading(
                visible: phase == _Phase.ask,
                child: Text(
                  s.rating_rate_hint,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              _Fading(
                visible: phase == _Phase.failed,
                child: Center(
                  child: CopyChip(
                    key: const Key('rating-copy'),
                    text: BazaarReviewLauncher.webListing.toString(),
                    label: s.rating_copy_link,
                    copiedLabel: s.rating_copied,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        _Fading(
          visible: secondary != null,
          child: TextButton(
            key: secondary == null ? null : const Key('rating-not-now'),
            onPressed: secondary == null || launching
                ? null
                : () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: _HandOverText(
              // Holds its last words while it fades, so the row keeps its
              // height and never collapses under the button.
              text: secondary ?? _lastSecondary ?? s.rating_not_now,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }
}

/// One phase's headline. Arriving, it rises a little and fades in after the
/// one before it has started to leave; leaving, it lifts and fades fast. It
/// is always laid out, so the stack it sits in never changes height.
class _Headline extends StatefulWidget {
  const _Headline({
    required this.title,
    required this.body,
    required this.visible,
    super.key,
  });

  final String title;
  final String body;
  final bool visible;

  @override
  State<_Headline> createState() => _HeadlineState();
}

class _HeadlineState extends State<_Headline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: AppMotion.sheet + AppMotion.press,
    reverseDuration: AppMotion.card,
    value: widget.visible ? 1 : 0,
  );

  @override
  void didUpdateWidget(_Headline old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (AppMotion.reduced(context)) {
      _shown.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _shown.forward();
    } else {
      _shown.reverse();
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          widget.body,
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
      ignoring: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: AnimatedBuilder(
          animation: _shown,
          child: content,
          builder: (context, child) {
            final v = _shown.value;
            if (v <= 0) return Opacity(opacity: 0, child: child);
            final arriving = _shown.status == AnimationStatus.forward;
            // Arrival waits for the leaver to be mostly gone: one dissolve,
            // never two lines of text on top of each other.
            final opacity = arriving
                ? const Interval(0.4, 1, curve: AppMotion.easeOut).transform(v)
                : v;
            final reduced = AppMotion.reduced(context);
            final dy = reduced
                ? 0.0
                : arriving
                ? 10 * (1 - AppMotion.easeOut.transform(v))
                : -8 * (1 - v);
            return Opacity(
              opacity: opacity,
              child: Transform.translate(offset: Offset(0, dy), child: child),
            );
          },
        ),
      ),
    );
  }
}

/// The controls landing once the stars have formed: they rise into room
/// that was theirs from the start, so the sheet does not grow.
class _Arrival extends StatelessWidget {
  const _Arrival({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        duration: AppMotion.entrance,
        curve: AppMotion.easeOut,
        opacity: visible ? 1 : 0,
        child: AnimatedSlide(
          duration: reduced ? Duration.zero : AppMotion.entrance,
          curve: AppMotion.easeOut,
          offset: visible || reduced ? Offset.zero : const Offset(0, 0.12),
          child: child,
        ),
      ),
    );
  }
}

/// Fades in place, keeping its room either way.
class _Fading extends StatelessWidget {
  const _Fading({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ExcludeSemantics(
      excluding: !visible,
      child: AnimatedOpacity(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        opacity: visible ? 1 : 0,
        child: child,
      ),
    ),
  );
}

/// Text that hands its words over in place: the old words lift away first,
/// then the new ones rise in, so the two never overlap.
class _HandOverText extends StatelessWidget {
  const _HandOverText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 340),
    switchInCurve: const Interval(0.45, 1, curve: AppMotion.easeOut),
    switchOutCurve: const Interval(0.45, 1, curve: AppMotion.easeOut),
    transitionBuilder: HandOver.transition(rise: 0.5, lift: 0.4),
    layoutBuilder: (current, previous) =>
        Stack(alignment: Alignment.center, children: [...previous, ?current]),
    child: KeyedSubtree(
      key: ValueKey(text),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    ),
  );
}

/// How close to a rider's face a tap must land to make them hop, in stage
/// units.
abstract final class RatingCartoonHit {
  static const double reach = 48;
}

enum _Glyph { stars, dots, heart, retry }

/// The story's one button, from the first ask to the last thanks.
///
/// It never swaps itself out: its fill and ink cross-fade to each phase's
/// colours, and its glyph and words hand over in place. While asking, five
/// tiny stars ripple across it on a loop, a quiet "this is the one"; while
/// Bazaar has the stage, three dots hop in turn.
class _MorphButton extends StatefulWidget {
  const _MorphButton({
    required this.label,
    required this.glyph,
    required this.fill,
    required this.ink,
    required this.onTap,
    this.labelKey,
  });

  final String label;
  final _Glyph glyph;
  final Color fill;
  final Color ink;
  final VoidCallback? onTap;

  /// Names the button by what it does right now, for tests.
  final Key? labelKey;

  @override
  State<_MorphButton> createState() => _MorphButtonState();
}

class _MorphButtonState extends State<_MorphButton>
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

  Widget _glyph(Color ink) => switch (widget.glyph) {
    _Glyph.stars => AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => CustomPaint(
        size: const Size(46, 18),
        painter: _StarRipplePainter(_loop.value, ink),
      ),
    ),
    _Glyph.dots => AnimatedBuilder(
      animation: _loop,
      builder: (context, _) => CustomPaint(
        size: const Size(34, 18),
        painter: _DotsPainter(_loop.value, ink),
      ),
    ),
    _Glyph.heart => Icon(Icons.favorite_rounded, size: 19, color: ink),
    _Glyph.retry => Icon(Icons.refresh_rounded, size: 19, color: ink),
  };

  @override
  Widget build(BuildContext context) {
    final onTap = widget.onTap;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: widget.label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: widget.fill),
          duration: AppMotion.sheet,
          curve: AppMotion.easeOut,
          builder: (context, fill, _) => TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: widget.ink),
            duration: AppMotion.sheet,
            curve: AppMotion.easeOut,
            builder: (context, ink, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: fill!.withValues(alpha: 0.28),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: SizedBox(
                height: 52,
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
                  transitionBuilder: HandOver.transition(rise: 0.5, lift: 0.4),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.center,
                    children: [...previous, ?current],
                  ),
                  child: Row(
                    key: ValueKey(widget.label),
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _glyph(ink!),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.label,
                          key: widget.labelKey,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ink,
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
        ),
      ),
    );
  }
}

/// Three dots hopping in turn, in the button's ink.
class _DotsPainter extends CustomPainter {
  _DotsPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / 3;
    for (var i = 0; i < 3; i++) {
      final hop = math.max(0.0, math.sin((t * 2 - i * 0.15) * math.pi * 2));
      canvas.drawCircle(
        Offset(step * (i + 0.5), size.height / 2 + 2 - 5 * hop),
        3.6,
        Paint()..color = color.withValues(alpha: 0.7 + 0.3 * hop),
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.t != t || old.color != color;
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
