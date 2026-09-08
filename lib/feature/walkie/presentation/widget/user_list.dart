import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/section_header.dart';
import '../../../room/api/room_api.dart';
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

/// Resolves the state shown for a durable Room member.
///
/// A live transport, a matching display name, or a single visible peer is not
/// membership evidence. Only the Room-scoped signed proof can grant
/// [RoomConnectionUiPhase.connected]. Keeping this resolver outside the widget
/// also makes the identity rule directly regression-testable.
RoomConnectionUiPhase roomRosterMemberPhase({
  required SavedRoom room,
  required RoomMember member,
  required RoomConnectionStatusData? verifiedStatus,
  required bool transportLive,
  required bool startFailed,
}) {
  if (member.pending) {
    return isHeldSeatPlaceholder(member.displayName)
        ? RoomConnectionUiPhase.invited
        : RoomConnectionUiPhase.confirming;
  }

  final verified = verifiedStatus;
  if (verified != null && verified.room.room.id == room.room.id) {
    return verified.phaseFor(member);
  }

  // A selected Room without its verified scope must fail closed. Transport
  // health can explain reconnecting/connecting, but can never identify which
  // durable member is on the other end.
  if (startFailed || !transportLive) {
    return RoomConnectionUiPhase.reconnecting;
  }
  return RoomConnectionUiPhase.connecting;
}

/// Shows people, not transport endpoints.
///
/// When a durable Room is selected, storage remains the membership authority
/// while the live Walkie state contributes presence only. A confirmed member
/// therefore stays visible through reconnects instead of disappearing with a
/// transient socket, and Host/Join/IP/SSID never leak into the normal Room UI.
/// Quick-access channels without a selected Room retain the legacy peer roster.
class UserList extends StatefulWidget {
  const UserList({super.key});

  @override
  State<UserList> createState() => _UserListState();
}

class _UserListState extends State<UserList> {
  RoomRepository? _rooms;
  SavedRoom? _room;
  StreamSubscription<void>? _roomChanges;
  int _reloadEpoch = 0;

  @override
  void initState() {
    super.initState();
    if (GetIt.instance.isRegistered<RoomRepository>()) {
      _rooms = GetIt.instance<RoomRepository>();
      _roomChanges = _rooms!.changes.listen((_) => unawaited(_reload()));
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    final rooms = _rooms;
    if (rooms == null) return;
    final epoch = ++_reloadEpoch;
    SavedRoom? next;
    try {
      final selected = await rooms.selectedRoomId();
      if (selected != null) {
        final candidate = await rooms.get(selected);
        if (candidate != null &&
            !candidate.room.archived &&
            candidate.membership.active) {
          next = candidate;
        }
      }
    } catch (_) {
      // Keep the last known durable roster through a transient storage read.
      return;
    }
    if (!mounted || epoch != _reloadEpoch) return;
    setState(() => _room = next);
  }

  @override
  void dispose() {
    _reloadEpoch++;
    unawaited(_roomChanges?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room != null) {
      return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
        // TX/presence changes are intentionally excluded here. Each durable
        // member row below selects only the talking bit for its exact verified
        // live sender, so one rider speaking cannot rebuild/relayout the whole
        // Room roster.
        buildWhen: (previous, current) =>
            previous.connectionHealth != current.connectionHealth ||
            previous.isReady != current.isReady ||
            previous.startFailed != current.startFailed,
        builder: (context, state) => _RoomRoster(room: room, live: state),
      );
    }
    return const _LegacyTransportRoster();
  }
}

class _RoomRoster extends StatelessWidget {
  const _RoomRoster({required this.room, required this.live});

  final SavedRoom room;
  final WalkieTalkieState live;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final allMembers = room.room.activeMembers;
    final remoteMembers = allMembers
        .where((member) => member.id != room.membership.localMemberId)
        .toList(growable: false);
    final verifiedStatus = RoomConnectionStatusScope.maybeOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          label: s.channel_members,
          badge: room.room.confirmedMembers.length.localized(context),
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
                        child: _RoomMemberPresenceTile(
                          member: member,
                          phase: roomRosterMemberPhase(
                            room: room,
                            member: member,
                            verifiedStatus: verifiedStatus,
                            transportLive: live.connectionHealth.isLive,
                            startFailed: live.startFailed,
                          ),
                          transportSenderId: verifiedStatus
                              ?.transportSenderIdFor(member),
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

/// Volatile speaking projection for one durable member only.
///
/// The selector never uses name matching. A row can react to live transport
/// presence only after the Room scope has supplied the sender id that arrived
/// with this exact member's verified current-generation route proof. Missing or
/// stale proof metadata therefore renders the row idle rather than guessing.
class _RoomMemberPresenceTile extends StatelessWidget {
  const _RoomMemberPresenceTile({
    required this.member,
    required this.phase,
    required this.transportSenderId,
  });

  final RoomMember member;
  final RoomConnectionUiPhase phase;
  final String? transportSenderId;

  @override
  Widget build(BuildContext context) {
    final senderId = transportSenderId;
    return BlocSelector<WalkieTalkieCubit, WalkieTalkieState, bool>(
      selector: (state) {
        if (phase != RoomConnectionUiPhase.connected || senderId == null) {
          return false;
        }
        for (final user in state.activeUsers) {
          if (user.id == senderId) return user.isTalking;
        }
        return false;
      },
      builder: (context, isTalking) =>
          _RoomMemberTile(member: member, phase: phase, isTalking: isTalking),
    );
  }
}

class _RoomMemberTile extends StatelessWidget {
  const _RoomMemberTile({
    required this.member,
    required this.phase,
    required this.isTalking,
  });

  final RoomMember member;
  final RoomConnectionUiPhase phase;
  final bool isTalking;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: s.people_unnamed,
    );
    final connected = phase == RoomConnectionUiPhase.connected;
    final active = connected || isTalking;

    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: active ? AppColors.green.withAlpha(15) : AppColors.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isTalking
                ? AppColors.green.withAlpha(180)
                : connected
                ? AppColors.green.withAlpha(130)
                : AppColors.border,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            AppAvatar(name: name, isActive: active, size: 38),
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
            if (isTalking) ...[
              const SizedBox(width: 8),
              const RepaintBoundary(child: WaveformBars()),
              const SizedBox(width: 8),
              Container(
                key: ValueKey('room-member-tx-${member.id.value}'),
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
            ],
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
      buildWhen: (previous, current) =>
          previous.activeUsers != current.activeUsers,
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
            final height = 6.0 + sin(_controller.value * pi + index * 1.2) * 6;
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
