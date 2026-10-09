import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/tark_mark.dart';
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
    this.avatarId,
    this.premium,
    super.key,
  });

  final RoomMember member;
  final double size;
  final bool ring;

  /// Whether to show the premium mark: what the live channel says about this
  /// member, or null for what was remembered from their last connection
  /// ([RoomMember.premium]).
  final bool? premium;

  /// The avatar this member announced in the live channel, when the Room is
  /// connected and their presence has been matched to them — see
  /// [TintedAvatar.avatarId]. Without one, the avatar remembered from their
  /// last connection ([RoomMember.avatarId]) is shown.
  final int? avatarId;

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
      avatarId: avatarId ?? member.avatarId,
      premium: premium ?? member.premium,
    );
  }
}

/// The face [MemberAvatar] draws, for someone known only by a [seed] (a
/// stable id) and a [name]: the live channel's peers outside a saved Room
/// look the same as the Room's members do.
///
/// With an [avatarId] the tinted initial gives way to that avatar's picture
/// (keeping the ring), so a picked avatar shows the same everywhere.
class TintedAvatar extends StatelessWidget {
  const TintedAvatar({
    required this.seed,
    required this.name,
    this.size = 44,
    this.ring = false,
    this.avatarId,
    this.premium = false,
    super.key,
  });

  final String seed;
  final String name;
  final double size;
  final bool ring;

  /// Adds the premium mark: a small amber star on the face's bottom corner.
  final bool premium;

  /// The person's picked avatar, or null (never picked, not known yet, or
  /// a phone too old to send one) for the tinted initial.
  final int? avatarId;

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
    final id = avatarId;
    final picture = AvatarPicture.shows(id);
    // A face that turns up (heard live, or remembered once the roster loads)
    // fades in over the initial instead of popping.
    final face = AnimatedSwitcher(
      duration: AppMotion.card,
      switchInCurve: AppMotion.easeOut,
      switchOutCurve: AppMotion.leaving,
      child: KeyedSubtree(
        key: ValueKey<int?>(picture ? id : null),
        child: _face(picture ? id : null),
      ),
    );
    final mark = size * 0.5;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        face,
        PositionedDirectional(
          end: -mark * 0.16,
          bottom: -mark * 0.16,
          child: PremiumMark(visible: premium, size: mark),
        ),
      ],
    );
  }

  Widget _face(int? id) {
    final initial = name.trim().isEmpty ? '?' : name.trim().characters.first;
    final tint = tintFor(seed);
    if (id != null) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: ring
              ? Border.all(color: AppColors.background, width: size * 0.047)
              : null,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: size * 0.25,
              offset: Offset(0, size * 0.06),
            ),
          ],
        ),
        child: AvatarPicture(avatarId: id, size: size),
      );
    }
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

/// The premium mark on a member's face: the Tarkk logo struck into a gold
/// medallion, ringed in the page colour so it sits on top of the face.
///
/// Turns up with a small twist as it grows in, and a glint sweeps across it
/// every few seconds while it shows. Under reduced motion it only fades and
/// the glint stays still.
class PremiumMark extends StatefulWidget {
  const PremiumMark({required this.visible, this.size = 20, super.key});

  final bool visible;
  final double size;

  /// The medallion's gold, light to deep, swept around its centre so the rim
  /// catches light on one side like struck metal.
  static const gold = [
    Color(0xFFFFE6A3),
    Color(0xFFF7B544),
    Color(0xFFC9771A),
    Color(0xFFF2A93B),
    Color(0xFFFFD98A),
    Color(0xFFFFE6A3),
  ];

  @override
  State<PremiumMark> createState() => _PremiumMarkState();
}

class _PremiumMarkState extends State<PremiumMark>
    with SingleTickerProviderStateMixin {
  /// One glint pass in the first part of each cycle, then a rest.
  late final AnimationController _glint = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncGlint();
  }

  @override
  void didUpdateWidget(PremiumMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _syncGlint();
  }

  /// Hidden marks keep no ticker running: a roster of free members costs
  /// nothing.
  void _syncGlint() {
    if (widget.visible) {
      _glint.loopUnlessReduced(context);
    } else {
      _glint
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _glint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final visible = widget.visible;
    final size = widget.size;
    return Semantics(
      label: visible ? context.getString.premium_badge : null,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
        child: AnimatedRotation(
          turns: visible || reduced ? 0 : -0.12,
          duration: reduced ? Duration.zero : AppMotion.sheet,
          curve: visible ? AppMotion.easeOut : AppMotion.leaving,
          child: AnimatedScale(
            scale: visible || reduced ? 1 : 0.4,
            duration: reduced ? Duration.zero : AppMotion.sheet,
            curve: visible ? AppMotion.easeOut : AppMotion.leaving,
            child: RepaintBoundary(
              child: _Medallion(
                key: const ValueKey('premium-mark'),
                size: size,
                glint: _glint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Medallion extends StatelessWidget {
  const _Medallion({required this.size, required this.glint, super.key});

  final double size;
  final Animation<double> glint;

  @override
  Widget build(BuildContext context) {
    final rim = math.max(1.5, size * 0.09);
    final logo = size * 0.54;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.background, width: rim),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF7B544).withValues(alpha: 0.45),
            blurRadius: size * 0.5,
          ),
        ],
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: SweepGradient(
                  colors: PremiumMark.gold,
                  transform: GradientRotation(-math.pi / 3),
                ),
              ),
            ),
            // A thin inner bevel: light along the top, shade along the
            // bottom, so the disc reads as raised rather than painted on.
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.38),
                    Colors.transparent,
                    const Color(0xFF7A3E00).withValues(alpha: 0.22),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
            Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Struck into the gold: a deep copy just below the logo.
                  Transform.translate(
                    offset: Offset(0, size * 0.035),
                    child: TarkMark(
                      size: logo,
                      color: const Color(0xFF8A4A06).withValues(alpha: 0.55),
                    ),
                  ),
                  TarkMark(
                    size: logo,
                    color: Colors.white,
                    colorDim: const Color(0xFFFFF0CC),
                  ),
                ],
              ),
            ),
            AnimatedBuilder(
              animation: glint,
              builder: (context, _) {
                // The pass takes the first quarter of the cycle; the band
                // starts and ends outside the disc so it never pops in.
                final t = (glint.value / 0.25).clamp(0.0, 1.0);
                if (t == 0 || t == 1) return const SizedBox.shrink();
                final x = -1.6 + 3.2 * Curves.easeInOut.transform(t);
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(x - 0.5, -1),
                      end: Alignment(x + 0.5, 1),
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.75),
                        Colors.white.withValues(alpha: 0),
                      ],
                      stops: const [0.3, 0.5, 0.7],
                    ),
                  ),
                );
              },
            ),
          ],
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
                // No premium marks in a stack: they would sit on the next face.
                child: MemberAvatar(
                  member: shown[i],
                  size: size,
                  ring: true,
                  premium: false,
                ),
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

/// Round connect control: the lobby's single start action drawn as a
/// power button rather than a full-width bar.
class RoomConnectButton extends StatelessWidget {
  const RoomConnectButton({
    required this.label,
    required this.onTap,
    this.busy = false,
    this.icon = Icons.power_settings_new_rounded,
    this.compact = false,
    super.key,
  });

  final String label;
  final bool busy;
  final IconData icon;
  final bool compact;
  final VoidCallback? onTap;

  static const _size = 84.0;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    if (compact) {
      return FilledButton.icon(
        onPressed: busy ? null : onTap,
        style: FilledButton.styleFrom(
          backgroundColor: amber,
          foregroundColor: Colors.black,
          minimumSize: const Size(double.infinity, 56),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        icon: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
        label: Text(label, textAlign: TextAlign.center),
      );
    }
    final radius = BorderRadius.circular(_size);
    return Semantics(
      button: true,
      enabled: !busy,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: busy ? null : onTap,
        scale: 0.95,
        borderRadius: radius,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: AppMotion.card,
              curve: AppMotion.easeOut,
              width: _size,
              height: _size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: busy ? amber.withValues(alpha: 0.14) : amber,
                border: Border.all(
                  color: amber.withValues(alpha: busy ? 0.45 : 0.0),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: amber.withValues(alpha: busy ? 0.0 : 0.22),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: AppMotion.chip,
                  switchInCurve: AppMotion.easeOut,
                  switchOutCurve: AppMotion.leaving,
                  child: busy
                      ? SizedBox(
                          key: const ValueKey('busy'),
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.6,
                            color: amber,
                          ),
                        )
                      : Icon(
                          icon,
                          key: ValueKey('idle'),
                          color: Colors.black,
                          size: 38,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: busy ? AppColors.textSecondary : amber,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
