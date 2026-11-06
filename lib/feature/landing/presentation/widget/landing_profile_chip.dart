import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/profile_hero.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';

/// Who you are, as a small chip in Home's top corner. Tapping it opens Profile.
///
/// This used to be a full-width card in the middle of Home, right above the
/// room. It had the same weight and shape as the room's button, so the screen
/// had two big things on it and neither one was clearly the thing to press.
/// Up here it sits opposite the settings chip, with the controls you visit
/// now and then, and the room is the only main action left.
///
/// The card's readiness line ("Ready" / "Can't find a network") is now a dot
/// on the avatar. It still appears instantly and is still announced, but it no
/// longer competes with the room for attention.
class LandingProfileChip extends StatelessWidget {
  const LandingProfileChip({
    super.key = const ValueKey('landing-identity'),
    required this.state,
    required this.onTap,
  });

  final LandingState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // Read off the plan rather than off `state.transferMode`, which is the
    // *last* transport used: only a plan with nowhere to go is not ready.
    final ready = !state.planFor(ChannelIntent.create).blocked;
    final status = state.isLoading
        ? s.connecting
        : (ready ? s.landing_ready : s.no_network);
    final name = state.myName.isEmpty ? '…' : state.myName;
    final dot = state.isLoading
        ? AppColors.textSecondary
        : (ready ? AppColors.green : AppColors.red);

    return Semantics(
      button: true,
      label: s.landing_profile_semantics(name, status),
      excludeSemantics: true,
      child: Padding(
        // Same outer padding as the settings chip opposite, so the two line
        // up and both keep a 48dp target.
        padding: const EdgeInsets.all(4),
        child: PressableScale(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: 40,
            padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 14, 4),
            decoration: BoxDecoration(
              color: AppColors.card.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ProfileHero.avatar(
                        name: state.myName,
                        avatarId: state.myAvatarId,
                        child: AppAvatar(
                          name: state.myName,
                          avatarId: state.myAvatarId,
                          size: 32,
                        ),
                      ),
                      PositionedDirectional(
                        end: -1,
                        bottom: -1,
                        child: AnimatedContainer(
                          key: const ValueKey('landing-identity-status'),
                          duration: AppMotion.card,
                          curve: AppMotion.easeOut,
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.background,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 9),
                ConstrainedBox(
                  // Long names stop well before the middle, so the chip never
                  // reaches the settings chip on a 320dp screen.
                  constraints: const BoxConstraints(maxWidth: 132),
                  child: ProfileHero.name(
                    name: name,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
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
}
