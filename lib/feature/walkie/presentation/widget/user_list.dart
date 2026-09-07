import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/section_header.dart';
import '../../../room/domain/entity/room.dart';
import '../../../room/presentation/room_member_display_name.dart';
import '../../../room/presentation/widget/in_room_people_action.dart';
import '../../../room/presentation/widget/room_connection_status_chip.dart';
import '../../../room/presentation/widget/room_connection_status_scope.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/channel_user.dart';
import '../manager/walkie_talkie_cubit.dart';
import 'role_badge.dart';

abstract final class RideMemberCount {
  static int total(int remotePeerCount) {
    if (remotePeerCount < 0) {
      throw ArgumentError.value(remotePeerCount, 'remotePeerCount');
    }
    return remotePeerCount + 1;
  }
}

/// Shows the people who belong to the current channel.
///
/// A selected durable Room uses its Room roster as the authority. The old
/// transfer peer list remains intact for quick-access channels that have no
/// Room. This prevents a confirmed Room member from disappearing merely because
/// their transport is reconnecting, and prevents a transient address/role from
/// becoming the user's idea of who is in the Room.
class UserList extends StatelessWidget {
  const UserList({super.key});

  @override
  Widget build(BuildContext context) {
    final room = RoomConnectionStatusScope.maybeOf(context);
    if (room != null) return _RoomRoster(data: room);
    return const _LegacyTransportRoster();
  }
}

class _RoomRoster extends StatelessWidget {
  const _RoomRoster({required this.data});

  final RoomConnectionStatusData data;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final allMembers = data.room.room.activeMembers;
    final remoteMembers = allMembers
        .where((member) => member.id != data.room.membership.localMemberId)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          label: s.channel_members,
          badge: allMembers.length.localized(context),
        ),
        const SizedBox(height: 10),
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          alignment: AlignmentDirectional.topStart,
          child: remoteMembers.isEmpty
              ? _EmptyRoster(label: s.no_users_on_network)
              : Column(
                  key: const ValueKey('room-roster'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final member in remoteMembers)
                      Padding(
                        key: ValueKey('room-member-${member.id.value}'),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RoomMemberTile(
                          member: member,
                          phase: data.phaseFor(member),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: InRoomPeopleAction(primary: false),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _RoomMemberTile extends StatelessWidget {
  const _RoomMemberTile({required this.member, required this.phase});

  final RoomMember member;
  final RoomConnectionUiPhase phase;

  @override
  Widget build(BuildContext context) {
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: context.getString.people_unnamed,
    );
    final connected = phase == RoomConnectionUiPhase.connected;

    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: connected ? AppColors.green.withAlpha(15) : AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: connected ? AppColors.green.withAlpha(130) : AppColors.border,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            AppAvatar(name: name, isActive: connected, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  RoomConnectionStatusChip(phase: phase),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacyTransportRoster extends StatelessWidget {
  const _LegacyTransportRoster();

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
                    ? _EmptyRoster(label: s.no_users_on_network)
                    : Column(
                        key: const ValueKey('list'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final user in users)
                            Padding(
                              key: ValueKey(user.id),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: UserTile(user: user),
                            ),
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

class _EmptyRoster extends StatelessWidget {
  const _EmptyRoster({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('empty'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.30)),
      ),
      child: Column(
        children: [
          Icon(Icons.group_add_rounded, color: AppColors.amber, size: 40),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const InRoomPeopleAction(primary: true),
        ],
      ),
    );
  }
}

class UserTile extends StatelessWidget {
  const UserTile({required this.user, super.key});

  final ChannelUser user;

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
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (index) {
            final height =
                6.0 + sin(_controller.value * pi + index * 1.2) * 6;
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
