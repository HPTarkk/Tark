import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../domain/entity/room.dart';
import '../room_member_display_name.dart';

/// The Room screens' shared visual vocabulary: members as tinted faces, the
/// amber-lit card a Room sits in while it is the one in play, and the wide
/// amber Start button. The lobby and the saved-rooms list both draw from
/// here, so a Room looks like the same object on both.

/// A circle with the member's initial, tinted from their id so each person
/// keeps the same colour on every phone and every visit.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    required this.member,
    this.size = 44,
    this.ring = false,
    super.key,
  });

  final RoomMember member;
  final double size;
  final bool ring;

  static Color tintFor(RoomMemberId id) => TintedAvatar.tintFor(id.value);

  @override
  Widget build(BuildContext context) {
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: context.getString.people_unnamed,
    );
    return TintedAvatar(
      seed: member.id.value,
      name: name,
      size: size,
      ring: ring,
    );
  }
}

/// The face [MemberAvatar] draws, for someone known only by a [seed] (a
/// stable id) and a [name]: the live channel's peers outside a saved Room
/// look the same as the Room's members do.
class TintedAvatar extends StatelessWidget {
  const TintedAvatar({
    required this.seed,
    required this.name,
    this.size = 44,
    this.ring = false,
    super.key,
  });

  final String seed;
  final String name;
  final double size;
  final bool ring;

  static Color tintFor(String seed) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    // Warm-to-cool hues that all sit well on both themes.
    const hues = [34.0, 12.0, 160.0, 200.0, 265.0, 330.0];
    return HSLColor.fromAHSL(1, hues[hash % hues.length], 0.62, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;
    final tint = tintFor(seed);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tint, Color.lerp(tint, Colors.black, 0.28)!],
        ),
        border: ring
            ? Border.all(color: AppColors.background, width: size * 0.047)
            : null,
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: 0.35),
            blurRadius: size * 0.25,
            offset: Offset(0, size * 0.06),
          ),
        ],
      ),
      child: Text(
        initial.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.4,
          height: 1,
        ),
      ),
    );
  }
}

/// Up to [maxShown] overlapping faces, then "+N".
class RoomFaces extends StatelessWidget {
  const RoomFaces({
    required this.members,
    this.size = 64,
    this.maxShown = 4,
    super.key,
  });

  final List<RoomMember> members;
  final double size;
  final int maxShown;

  /// How far each face tucks under the next — the same proportion at every
  /// size, so a small stack reads as the lobby's cluster scaled down.
  double get _overlap => size * 0.31;

  /// The width a full stack of [maxShown] faces takes, for callers that line
  /// several stacks up in a column.
  static double widthFor({required double size, required int slots}) =>
      size + (slots - 1) * (size - size * 0.31);

  @override
  Widget build(BuildContext context) {
    final shown = members.take(maxShown).toList(growable: false);
    final extra = members.length - shown.length;
    final count = shown.length + (extra > 0 ? 1 : 0);
    if (count == 0) return const SizedBox.shrink();
    final step = size - _overlap;
    final width = size + (count - 1) * step;
    return ExcludeSemantics(
      child: SizedBox(
        width: width,
        height: size,
        child: Stack(
          children: [
            for (var i = 0; i < shown.length; i++)
              PositionedDirectional(
                start: i * step,
                child: MemberAvatar(member: shown[i], size: size, ring: true),
              ),
            if (extra > 0)
              PositionedDirectional(
                start: shown.length * step,
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.card,
                    border: Border.all(
                      color: AppColors.background,
                      width: size * 0.047,
                    ),
                  ),
                  child: Text(
                    '+${extra.localized(context)}',
                    // A count, not a phrase: kept left-to-right so Persian
                    // reads "+۴" rather than the bidi-flipped "۴+".
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: size * 0.25,
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

/// The amber-lit surface of the Room currently in play: a warm glow from
/// above, a faint amber rim. [lit] false is the plain card every other Room
/// sits on, so the two animate into each other.
BoxDecoration roomCardDecoration({
  required bool lit,
  required BorderRadius radius,
}) {
  final amber = AppColors.amber;
  return BoxDecoration(
    borderRadius: radius,
    color: AppColors.surface,
    border: Border.all(
      color: lit ? amber.withValues(alpha: 0.45) : AppColors.border,
      width: lit ? 1.5 : 1,
    ),
    gradient: RadialGradient(
      center: const Alignment(0, -0.9),
      radius: 1.3,
      colors: [
        amber.withValues(alpha: lit ? 0.18 : 0.0),
        AppColors.surface.withValues(alpha: 0.0),
      ],
    ),
    boxShadow: [
      BoxShadow(
        color: amber.withValues(alpha: lit ? 0.12 : 0.0),
        blurRadius: 28,
        spreadRadius: 1,
      ),
    ],
  );
}

/// The one thing on a Room screen that matters: a wide amber button that
/// gives under the finger and becomes a progress indicator once pressed. In
/// the lobby it also breathes ([breathe]) while it waits for a tap.
class RoomStartButton extends StatelessWidget {
  const RoomStartButton({
    required this.label,
    required this.onTap,
    this.busy = false,
    this.breathe = true,
    this.icon = Icons.play_arrow_rounded,
    this.height = 62,
    super.key,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  /// The slow amber pulse. Reserved for the screen's single most important
  /// action, and it never settles — so only where nothing else is asking.
  final bool breathe;
  final IconData icon;
  final double height;

  static final _radius = BorderRadius.circular(20);

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final button = PressableScale(
      onTap: busy ? null : onTap,
      borderRadius: _radius,
      child: AnimatedContainer(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        height: height,
        decoration: BoxDecoration(
          borderRadius: _radius,
          gradient: LinearGradient(
            begin: AlignmentDirectional.centerStart,
            end: AlignmentDirectional.centerEnd,
            colors: busy
                ? [amber.withValues(alpha: 0.22), amber.withValues(alpha: 0.14)]
                : [amber, Color.lerp(amber, Colors.deepOrange, 0.35)!],
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: AppMotion.chip,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
                  child: child,
                ),
              ),
              child: busy
                  ? SizedBox(
                      key: const ValueKey('busy'),
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: amber,
                      ),
                    )
                  : Icon(
                      icon,
                      key: const ValueKey('idle'),
                      color: Colors.black,
                      size: height * 0.45,
                    ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: busy ? amber : Colors.black,
                  fontSize: height >= 60 ? 16 : 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: !busy,
      label: label,
      excludeSemantics: true,
      child: breathe
          ? PulseGlow(enabled: !busy, borderRadius: _radius, child: button)
          : button,
    );
  }
}
