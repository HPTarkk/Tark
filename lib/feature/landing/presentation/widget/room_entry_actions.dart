import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../../core/widget/monogram_mark.dart';

/// How an entry action is drawn. Weight, not decoration: each variant says
/// something different about what the thing is.
enum RoomEntryVariant {
  /// The one thing this screen is for. Fill, glow, and a slow breath.
  hero,

  /// A quiet full-width row. Used when there is only one alternative to the
  /// hero and a pair would be a row of one.
  wide,

  /// Half of a pair. Two of these side by side say "these are alternatives to
  /// each other", which is the whole reason the pair exists.
  compact,
}

/// The ways into the product, drawn as one decision with three weights.
///
/// The old version took a flat `List` of actions and a `primary` bool, which
/// could only ever express a **binary** — one loud card and a flat tier under
/// it. With three options that is a list with a highlight on it, not a
/// hierarchy, and it was the reason nothing on the screen said which thing you
/// were meant to press. Worse, "create a new room" was not an option at all: it
/// lived inside MY ROOMS' hint text, which is the weakest place on the screen
/// for the second-most-likely action.
///
/// So the tiers are the type now. A caller cannot accidentally produce a flat
/// list, because there is nowhere to put one.
class RoomEntryActions extends StatelessWidget {
  const RoomEntryActions({
    required this.hero,
    this.alternatives = const [],
    this.browse,
    super.key,
  });

  /// What the user almost certainly came here to do.
  final RoomEntryAction hero;

  /// Ways to begin something new — equals to *each other*, and quieter than
  /// [hero]. Two are laid out side by side; one takes the full width, because a
  /// pair of one is just a card that has been made narrow for no reason.
  final List<RoomEntryAction> alternatives;

  /// Navigation, not an action. Deliberately not a card: browsing a list is a
  /// different kind of thing from starting or joining a ride, and giving it the
  /// same shape as those is what made three options read as three peers.
  final Widget? browse;

  @override
  Widget build(BuildContext context) {
    final pair = alternatives.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        hero,
        if (alternatives.isNotEmpty) ...[
          const SizedBox(height: 14),
          if (pair)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < alternatives.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(child: alternatives[i]),
                  ],
                ],
              ),
            )
          else
            alternatives.single,
        ],
        if (browse != null) ...[const SizedBox(height: 6), browse!],
      ],
    );
  }
}

/// One entry action.
///
/// The hero variant breathes. Its border colour and its glow are driven by the
/// same slow cycle, so they read as one object catching the light rather than
/// as two effects that happen to share a timer — which is the difference
/// between this looking designed and looking animated.
class RoomEntryAction extends StatefulWidget {
  const RoomEntryAction({
    required this.icon,
    required this.label,
    required this.hint,
    required this.variant,
    required this.onTap,
    this.monogram,
    super.key,
  });

  final IconData icon;
  final String label;
  final String hint;
  final RoomEntryVariant variant;
  final VoidCallback onTap;

  /// Drawn in place of [icon] when set — the room's own mark, so resuming a
  /// room looks like the card it was chosen on.
  final String? monogram;

  /// Re-weights an action without restating it, so a caller that builds the
  /// same button in two arrangements does not have to keep two copies of its
  /// labels in step.
  RoomEntryAction copyWith({RoomEntryVariant? variant}) => RoomEntryAction(
    key: key,
    icon: icon,
    label: label,
    hint: hint,
    variant: variant ?? this.variant,
    onTap: onTap,
    monogram: monogram,
  );

  @override
  State<RoomEntryAction> createState() => _RoomEntryActionState();
}

class _RoomEntryActionState extends State<RoomEntryAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );
  late final Animation<double> _pulse = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  bool get _hero => widget.variant == RoomEntryVariant.hero;

  /// Resolved here rather than in `initState`, which cannot reach an inherited
  /// widget — and rather than only at paint time, because a controller left
  /// repeating under reduced motion still costs a frame callback for something
  /// nobody is being shown.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(RoomEntryAction old) {
    super.didUpdateWidget(old);
    if (widget.variant != old.variant) _syncPulse();
  }

  void _syncPulse() {
    final shouldPulse = _hero && !AppMotion.reduced(context);
    if (shouldPulse == _controller.isAnimating) return;
    if (shouldPulse) {
      _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static final _radius = BorderRadius.circular(16);
  static final _heroRadius = BorderRadius.circular(20);

  @override
  Widget build(BuildContext context) {
    final quiet = !_hero || AppMotion.reduced(context);
    return Semantics(
      button: true,
      label: '${widget.label}. ${widget.hint}',
      excludeSemantics: true,
      child: PressableScale(
        onTap: widget.onTap,
        borderRadius: _hero ? _heroRadius : _radius,
        child: quiet
            ? _shell(context, pulse: 0)
            // The subtree is handed through `child:` so the pulse repaints a
            // shadow and a nudge and nothing else — no text layout, no icon
            // raster, sixty times a second on the floor device.
            : RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _pulse,
                  child: _content(context),
                  builder: (context, child) =>
                      _shell(context, pulse: _pulse.value, child: child),
                ),
              ),
      ),
    );
  }

  /// The hero is the only filled thing on Home.
  ///
  /// It used to be a tinted card with a brighter border, sat on top of two
  /// cards that were each *taller* than it and wore the same amber edge. Read
  /// at a glance that was three cards of a family, and the biggest two were
  /// not the one that mattered — which is exactly the "no hierarchy" that was
  /// reported. A solid fill is the one signal nothing else on the screen
  /// shares, so it carries the hierarchy on its own; size and the glow only
  /// confirm it.
  Widget _shell(BuildContext context, {required double pulse, Widget? child}) {
    if (!_hero) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.fieldCard,
          borderRadius: _radius,
          // Neutral, not amber: amber is the hero's colour, and an amber edge
          // on the alternatives is what made them read as its siblings.
          border: Border.all(color: AppColors.border),
        ),
        child: child ?? _content(context),
      );
    }
    final fill = HeroFill.of();
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [fill.start, fill.start, fill.end],
          stops: const [0, 0.45, 1],
        ),
        borderRadius: _heroRadius,
        boxShadow: [
          BoxShadow(
            color: AppColors.amber.withValues(alpha: 0.18 + 0.16 * pulse),
            blurRadius: 22 + 10 * pulse,
            spreadRadius: 1 * pulse,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child ?? _content(context),
    );
  }

  Widget _content(BuildContext context) => switch (widget.variant) {
    RoomEntryVariant.hero => _heroContent(context),
    RoomEntryVariant.wide => _wide(context),
    RoomEntryVariant.compact => _compact(context),
  };

  /// Mark, name, and a "go" disc at the far edge.
  ///
  /// The disc is what makes a card read as a button you press rather than a
  /// summary you look at. Its arrow follows the reading direction, so in
  /// Persian it points the way the eye is already travelling.
  Widget _heroContent(BuildContext context) {
    final ink = HeroFill.of().ink;
    final reduced = AppMotion.reduced(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 18, 14, 18),
      child: Row(
        children: [
          _swap(
            ValueKey(widget.monogram ?? widget.icon),
            _heroLeading(ink),
            reduced: reduced,
          ),
          const SizedBox(width: 14),
          Expanded(
            // Keyed by the label so a different Room arriving from storage —
            // picked on the list one screen up — slides in as a new object
            // instead of its name simply changing under the user's thumb.
            child: _swap(
              ValueKey(widget.label),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ink,
                      fontSize: 19,
                      height: 1.2,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ink.withValues(alpha: 0.86),
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              reduced: reduced,
            ),
          ),
          const SizedBox(width: 12),
          _GoDisc(ink: ink, nudge: reduced ? null : _pulse),
        ],
      ),
    );
  }

  Widget _swap(Key key, Widget child, {required bool reduced}) =>
      AnimatedSwitcher(
        duration: reduced ? Duration.zero : AppMotion.sheet,
        switchInCurve: AppMotion.easeOut,
        switchOutCurve: AppMotion.leaving,
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.35),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: key, child: child),
      );

  Widget _heroLeading(Color ink) {
    final monogram = widget.monogram;
    if (monogram == null) {
      return Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: ink.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Icon(widget.icon, color: ink, size: 24),
      );
    }
    return MonogramMark(name: monogram, accent: ink, size: 48, strong: true);
  }

  /// A quiet full-width row: the only alternative on a first run.
  Widget _wide(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Icon(widget.icon, color: AppColors.textPrimary, size: 22),
        const SizedBox(width: 14),
        Expanded(child: _quietWords(labelSize: 14.5, hintLines: 2)),
      ],
    ),
  );

  /// Half of a pair: icon beside the words, so the pair stays a short strip
  /// under the hero instead of two tall tiles that outweigh it.
  Widget _compact(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(12, 11, 10, 11),
    child: Row(
      children: [
        Icon(widget.icon, color: AppColors.textPrimary, size: 20),
        const SizedBox(width: 10),
        Expanded(child: _quietWords(labelSize: 12.5, hintLines: 1)),
      ],
    ),
  );

  Widget _quietWords({required double labelSize, required int hintLines}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: labelSize,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            widget.hint,
            maxLines: hintLines,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ],
      );
}

/// The hero's fill and the ink drawn on it, per theme.
///
/// Worked out for contrast rather than picked by eye: dark ink on the dark
/// theme's bright amber, white on a deepened brass in the light theme, where
/// white on the plain brass would fall under 4.5:1 for the hint line.
@visibleForTesting
class HeroFill {
  const HeroFill._(this.start, this.end, this.ink);

  final Color start;
  final Color end;
  final Color ink;

  static HeroFill of() => ThemeService.isLight
      ? HeroFill._(
          Color.lerp(AppColors.amber, AppColors.amberDim, 0.5)!,
          AppColors.amberDim,
          const Color(0xFFFFFFFF),
        )
      : HeroFill._(
          AppColors.amber,
          Color.lerp(AppColors.amber, AppColors.amberDim, 0.6)!,
          AppColors.background,
        );
}

/// The hero's "go" affordance. It leans forward on the same breath that lifts
/// the glow, so the two read as one object inviting a press.
class _GoDisc extends StatelessWidget {
  const _GoDisc({required this.ink, required this.nudge});

  final Color ink;
  final Animation<double>? nudge;

  @override
  Widget build(BuildContext context) {
    final disc = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.arrow_forward_rounded, color: ink, size: 22),
    );
    final nudge = this.nudge;
    if (nudge == null) return disc;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: nudge,
      child: disc,
      builder: (_, child) => Transform.translate(
        offset: Offset((rtl ? -3 : 3) * nudge.value, 0),
        child: child,
      ),
    );
  }
}

/// The way to the full list, drawn as navigation rather than as a fourth card.
///
/// It carries the count for the same reason the archive pill does (R16): the
/// failure being fixed is people not knowing what is behind it, and a bare
/// glyph would only have made that one tap less visible.
class RoomBrowseLink extends StatelessWidget {
  const RoomBrowseLink({
    required this.label,
    required this.count,
    required this.onTap,
    super.key,
  });

  final String label;

  /// Already localized — Persian rooms are counted in Persian digits.
  final String count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label ($count)',
    excludeSemantics: true,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        // Borderless, but still a 44dp target: the padding is the control.
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
        child: Row(
          children: [
            Icon(
              Icons.groups_2_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
            Text(
              count,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    ),
  );
}
