import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
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
          const SizedBox(height: 12),
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

  @override
  Widget build(BuildContext context) {
    final quiet = !_hero || AppMotion.reduced(context);
    return Semantics(
      button: true,
      label: '${widget.label}. ${widget.hint}',
      excludeSemantics: true,
      child: PressableScale(
        onTap: widget.onTap,
        borderRadius: _radius,
        child: quiet
            ? _shell(context, pulse: 0)
            // The subtree is handed through `child:` so the pulse repaints a
            // border and a shadow and nothing else — no text layout, no icon
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

  Widget _shell(BuildContext context, {required double pulse, Widget? child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _hero ? AppColors.amber.withValues(alpha: 0.10) : AppColors.card,
        borderRadius: _radius,
        border: Border.all(
          color: _hero
              ? Color.lerp(
                  AppColors.amber,
                  AppColors.amber.withValues(alpha: 0.47),
                  pulse,
                )!
              : AppColors.amber.withValues(alpha: 0.35),
          width: _hero ? 2 : 1,
        ),
        boxShadow: _hero
            ? [
                BoxShadow(
                  color: AppColors.amber.withValues(alpha: 0.06 + 0.16 * pulse),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: child ?? _content(context),
    );
  }

  Widget _content(BuildContext context) => switch (widget.variant) {
    RoomEntryVariant.compact => _stacked(context),
    _ => _inline(context),
  };

  /// Icon beside the words. Enough room for a full sentence of hint.
  Widget _inline(BuildContext context) {
    final accent = _hero ? AppColors.amber : AppColors.textPrimary;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: _hero ? 16 : 15),
      child: Row(
        children: [
          _leading(accent),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: _hero ? 16 : 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: _hero ? 1.2 : 2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.hint,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Icon over the words, centred — half the width, so the row shape that works
  /// full-bleed would leave the label two characters wide at 320.
  Widget _stacked(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(widget.icon, color: AppColors.textPrimary, size: 22),
        const SizedBox(height: 9),
        Text(
          widget.label,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.hint,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 10.5,
            height: 1.3,
          ),
        ),
      ],
    ),
  );

  Widget _leading(Color accent) {
    final monogram = widget.monogram;
    if (monogram == null) return Icon(widget.icon, color: accent, size: 22);
    return MonogramMark(name: monogram, accent: accent, size: 42, strong: true);
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
