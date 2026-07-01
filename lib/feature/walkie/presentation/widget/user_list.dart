import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../walkie/domain/entity/channel_user.dart';
import '../manager/walkie_talkie_cubit.dart';

// ── Section header helper ─────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String label;
  final String? badge;

  const SectionHeader({super.key, required this.label, this.badge});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          color: AppColors.amber,
          margin: const EdgeInsetsDirectional.only(end: 8),
        ),
        Text(
          label,
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: badge != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: Container(
                        key: ValueKey(badge),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.amber.withAlpha(40),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          badge!,
                          style: TextStyle(
                            color: AppColors.amber,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// ── User list ─────────────────────────────────────────────────────────────────

/// Shows the list of active channel members or an empty-state card.
class UserList extends StatelessWidget {
  const UserList({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.activeUsers != c.activeUsers,
      builder: (context, state) {
        final users = state.activeUsers;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              label: s.channel_members,
              badge: users.isEmpty ? null : users.length.localized(context),
            ),
            const SizedBox(height: 10),
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              alignment: AlignmentDirectional.topStart,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: users.isEmpty
                    ? Container(
                        key: const ValueKey('empty'),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.wifi_tethering_off_rounded,
                                color: AppColors.textSecondary.withAlpha(120),
                                size: 32,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                s.no_users_on_network,
                                style: TextStyle(
                                  color: AppColors.textSecondary.withAlpha(160),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    : Column(
                        key: const ValueKey('list'),
                        children: users
                            .map(
                              (u) => Padding(
                                key: ValueKey(u.id),
                                padding: const EdgeInsets.only(bottom: 8),
                                child: UserTile(user: u),
                              ),
                            )
                            .toList(),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── User tile ─────────────────────────────────────────────────────────────────

class UserTile extends StatelessWidget {
  final ChannelUser user;

  const UserTile({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final isTalking = user.isTalking;
    final s = context.getString;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: isTalking ? AppColors.green.withAlpha(15) : AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isTalking ? AppColors.green.withAlpha(180) : AppColors.border,
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          AppAvatar(name: user.name, isActive: isTalking, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  user.id.localized(context),
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (isTalking) ...[
            // Self-contained animation — does not rebuild the parent tile.
            const RepaintBoundary(child: WaveformBars()),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.green.withAlpha(40),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppColors.green.withAlpha(100)),
              ),
              child: Text(
                s.tx_label,
                style: TextStyle(
                  color: AppColors.green,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
          ] else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.border.withAlpha(80),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                s.user_idle,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Waveform bars ─────────────────────────────────────────────────────────────

/// Self-contained animated bars shown next to a talking user.
///
/// Owns its own [AnimationController] so no parent widget needs to drive it.
class WaveformBars extends StatefulWidget {
  const WaveformBars({super.key});

  @override
  State<WaveformBars> createState() => _WaveformBarsState();
}

class _WaveformBarsState extends State<WaveformBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          final height = 6.0 + sin(_controller.value * pi + i * 1.2) * 6;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Container(
              width: 3,
              height: height.abs() + 2,
              decoration: BoxDecoration(
                color: AppColors.green,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}
