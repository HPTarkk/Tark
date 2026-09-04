import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/section_header.dart';
import '../../../room/presentation/widget/in_room_people_action.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/channel_user.dart';
import '../manager/walkie_talkie_cubit.dart';
import 'role_badge.dart';

/// Ride Mode's displayed member total.
///
/// [WalkieTalkieState.activeUsers] is intentionally the remote-peer roster;
/// the local rider is rendered separately in the identity card. The visible
/// Room/channel count must nevertheless include that local participant exactly
/// once, so presentation code uses this policy instead of relabeling the peer
/// roster or injecting a fake self peer into transport state.
abstract final class RideMemberCount {
  static int total(int remotePeerCount) {
    if (remotePeerCount < 0) {
      throw ArgumentError.value(remotePeerCount, 'remotePeerCount');
    }
    return remotePeerCount + 1;
  }
}

// ── User list ─────────────────────────────────────────────────────────────────

/// Shows the list of active channel members or an empty-state card.
///
/// **This card is also where you add someone (R32).** The invite used to be a
/// pill in the header, on the trailing edge of a screen a rider stares at for
/// the whole trip, for something they do once a ride at most. Here it sits
/// under the question it answers — and it can change weight with the answer,
/// which a header pill could not: on a channel with nobody else on it, the
/// empty card stops being a dead end and carries the lit control instead.
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
              badge: RideMemberCount.total(users.length).localized(context),
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
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                        decoration: BoxDecoration(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(14),
                          // Amber rather than the flat border it had. The card
                          // is no longer reporting a nil result; it is asking
                          // for something.
                          border: Border.all(
                            color: AppColors.amber.withValues(alpha: 0.30),
                          ),
                        ),
                        child: Column(
                          children: [
                            // A people mark, not the tethering-off glyph that
                            // used to sit here. Nobody being on the channel is
                            // a fact about people; whether the *link* is
                            // healthy is already answered by the banners and
                            // the signal meter above.
                            Icon(
                              Icons.group_add_rounded,
                              color: AppColors.amber,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              s.no_users_on_network,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            // Renders nothing on a channel with no durable
                            // Room, which leaves exactly the card this used to
                            // be: a mark and the situation in one line.
                            const InRoomPeopleAction(primary: true),
                          ],
                        ),
                      )
                    : Column(
                        key: const ValueKey('list'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final u in users)
                            Padding(
                              key: ValueKey(u.id),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: UserTile(user: u),
                            ),
                          // Quiet, and below the list: with somebody already
                          // here the screen's attention belongs to the mic,
                          // and this is a thing you go looking for rather than
                          // one that should catch your eye.
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: InRoomPeopleAction(primary: false),
                          ),
                        ],
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
          // The second line carries the part this member plays in the link.
          // It used to be their address — a MAC over Bluetooth, an IP over
          // Wi-Fi — which says nothing to the person reading it; who is
          // holding the channel up does.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
                if (user.role != SessionRole.unknown) ...[
                  const SizedBox(height: 3),
                  RoleBadge(role: user.role),
                ],
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
    // Loops at frame rate while visible; keep the repaint local to the bars
    // instead of invalidating the whole member list's layer.
    return RepaintBoundary(
      child: AnimatedBuilder(
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
      ),
    );
  }
}
