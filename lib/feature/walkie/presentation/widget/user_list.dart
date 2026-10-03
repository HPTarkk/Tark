import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/section_header.dart';
import '../../../room/api/room_api.dart';
import '../../../room/presentation/widget/room_visuals.dart';
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

/// Writes [avatarId] onto [memberId]'s row in [room], after the current
/// frame and only when it differs from what the Room already has.
///
/// Best effort: a face is display metadata, so a failed write just leaves the
/// lobby on the initial until the next ride.
void _rememberRoomMemberAvatar(
  SavedRoom room,
  RoomMemberId memberId,
  int avatarId,
) {
  if (!GetIt.instance.isRegistered<RoomRepository>()) return;
  final rooms = GetIt.instance<RoomRepository>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      rooms
          .updateMember(room.room.id, memberId, avatarId: avatarId)
          .then<void>((_) {}, onError: (_) {}),
    );
  });
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
    final confirmedRemoteMembers = allMembers
        .where(
          (member) =>
              !member.pending && member.id != room.membership.localMemberId,
        )
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
          child: confirmedRemoteMembers.isEmpty
              ? _EmptyRoster(label: s.no_users_on_network)
              : Column(
                  key: const ValueKey('room-roster'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final member in confirmedRemoteMembers)
                      Padding(
                        key: ValueKey('room-member-${member.id.value}'),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _RoomMemberPresenceTile(
                          room: room,
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
        // Held invite seats stay out of the call, as they stay out of the
        // lobby: a code nobody has scanned is not somebody in the Room.
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
///
/// The same proof-matched sender is how a member who dropped out is noticed: a
/// proof stays valid for the whole connection, so without this the row went on
/// saying "connected" for someone whose app had stopped minutes ago. Once they
/// have been heard here and then go quiet past the roster's timeout, the row
/// turns [RoomConnectionUiPhase.away] and waits for them to come back.
class _RoomMemberPresenceTile extends StatefulWidget {
  const _RoomMemberPresenceTile({
    required this.room,
    required this.member,
    required this.phase,
    required this.transportSenderId,
  });

  final SavedRoom room;
  final RoomMember member;
  final RoomConnectionUiPhase phase;
  final String? transportSenderId;

  @override
  State<_RoomMemberPresenceTile> createState() =>
      _RoomMemberPresenceTileState();
}

class _RoomMemberPresenceTileState extends State<_RoomMemberPresenceTile> {
  /// Heard on this live screen at least once. A member who never was is
  /// still arriving, not gone.
  bool _seen = false;

  /// For an open code sheet: true again once this member is heard.
  final ValueNotifier<bool> _back = ValueNotifier(true);

  /// The face last written to the Room for this member, so one sighting is
  /// one write rather than one per rebuild.
  int? _remembered;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  /// Keeps the face this member showed live on their Room row, so the lobby
  /// and the Rooms list show it too while nobody is connected.
  void _remember(int? avatarId) {
    if (avatarId == null ||
        avatarId == widget.member.avatarId ||
        avatarId == _remembered) {
      return;
    }
    _remembered = avatarId;
    _rememberRoomMemberAvatar(widget.room, widget.member.id, avatarId);
  }

  bool _settled(RoomConnectionUiPhase phase) =>
      phase == RoomConnectionUiPhase.connected ||
      phase == RoomConnectionUiPhase.reconnecting;

  @override
  Widget build(BuildContext context) {
    final senderId = widget.transportSenderId;
    final phase = widget.phase;
    return BlocSelector<WalkieTalkieCubit, WalkieTalkieState, bool>(
      selector: (state) {
        if (senderId == null) return false;
        for (final user in state.activeUsers) {
          if (user.id == senderId) return true;
        }
        return false;
      },
      builder: (context, present) {
        if (present) _seen = true;
        final away = senderId != null && _seen && !present && _settled(phase);
        // After the frame: an open code sheet listens, and a listener must
        // not rebuild another route in the middle of this one's build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _back.value = !away;
        });
        final shown = away ? RoomConnectionUiPhase.away : phase;
        return BlocSelector<WalkieTalkieCubit, WalkieTalkieState, bool>(
          selector: (state) {
            if (shown != RoomConnectionUiPhase.connected || senderId == null) {
              return false;
            }
            for (final user in state.activeUsers) {
              if (user.id == senderId) return user.isTalking;
            }
            return false;
          },
          // The avatar rides the same proof-matched sender id as the talking
          // flag, so it is only ever shown for this exact member. A selector
          // of its own, so a talk onset does not re-resolve it and vice versa.
          builder: (context, isTalking) =>
              BlocSelector<WalkieTalkieCubit, WalkieTalkieState, int?>(
                selector: (state) {
                  if (senderId == null) return null;
                  for (final user in state.activeUsers) {
                    if (user.id == senderId) return user.avatarId;
                  }
                  return null;
                },
                builder: (context, avatarId) {
                  _remember(avatarId);
                  return _RoomMemberTile(
                    room: widget.room,
                    member: widget.member,
                    phase: shown,
                    isTalking: isTalking,
                    avatarId: avatarId,
                    back: _back,
                  );
                },
              ),
        );
      },
    );
  }
}

class _RoomMemberTile extends StatelessWidget {
  const _RoomMemberTile({
    required this.room,
    required this.member,
    required this.phase,
    required this.isTalking,
    required this.back,
    this.avatarId,
  });

  final SavedRoom room;
  final RoomMember member;
  final RoomConnectionUiPhase phase;
  final bool isTalking;
  final ValueListenable<bool> back;
  final int? avatarId;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: s.people_unnamed,
    );
    final connected = phase == RoomConnectionUiPhase.connected;
    final away = phase == RoomConnectionUiPhase.away;
    final active = connected || isTalking;

    return Semantics(
      container: true,
      child: AnimatedContainer(
        duration: AppMotion.card,
        curve: AppMotion.easeOut,
        padding: _kRowPadding,
        decoration: _memberRowDecoration(
          talking: isTalking,
          live: active,
          away: away,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _TalkingFace(
                  talking: isTalking,
                  away: away,
                  child: MemberAvatar(
                    member: member,
                    size: _kFaceSize,
                    avatarId: avatarId,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedDefaultTextStyle(
                        duration: AppMotion.card,
                        curve: AppMotion.easeOut,
                        style: TextStyle(
                          color: away
                              ? AppColors.textSecondary
                              : AppColors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 4),
                      RoomConnectionStatusChip(phase: phase),
                    ],
                  ),
                ),
                if (isTalking) ...[
                  const SizedBox(width: 8),
                  _TalkingMark(
                    key: ValueKey('room-member-tx-${member.id.value}'),
                    label: s.tx_label,
                  ),
                ],
              ],
            ),
            // Opens under the row rather than replacing it: the person is
            // still in the Room, and this is only what the Room is doing
            // about them.
            AnimatedSize(
              duration: AppMotion.sheet,
              curve: AppMotion.easeOut,
              alignment: AlignmentDirectional.topStart,
              child: AnimatedSwitcher(
                duration: AppMotion.card,
                switchInCurve: AppMotion.easeOut,
                switchOutCurve: AppMotion.leaving,
                child: away
                    ? Padding(
                        key: ValueKey('room-member-away-${member.id.value}'),
                        padding: const EdgeInsetsDirectional.only(
                          top: 10,
                          start: _kFaceSize + 16,
                        ),
                        child: RoomAwayMemberHelp(
                          room: room,
                          member: member,
                          name: name,
                          back: back,
                        ),
                      )
                    : const SizedBox(width: double.infinity),
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
              duration: AppMotion.card,
              curve: AppMotion.easeOut,
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
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      padding: _kRowPadding,
      decoration: _memberRowDecoration(talking: isTalking, live: isTalking),
      child: Row(
        children: [
          _TalkingFace(
            talking: isTalking,
            child: TintedAvatar(
              seed: user.id,
              name: user.name,
              size: _kFaceSize,
              avatarId: user.avatarId,
            ),
          ),
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
          if (isTalking)
            _TalkingMark(label: s.tx_label)
          else
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

// ── Member row pieces ────────────────────────────────────────────────────────
//
// The Room lobby's member card, carried into the live channel: the same
// surface, radius and tinted faces, so a Room reads as the same group once it
// is live. Talking lights the row green — the channel's colour for "them".

const double _kFaceSize = 40;
const EdgeInsets _kRowPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 10,
);

BoxDecoration _memberRowDecoration({
  required bool talking,
  required bool live,
  bool away = false,
}) {
  final green = AppColors.green;
  return BoxDecoration(
    color: talking
        ? Color.alphaBlend(green.withValues(alpha: 0.08), AppColors.surface)
        : AppColors.surface,
    borderRadius: BorderRadius.circular(18),
    border: Border.all(
      color: talking
          ? green.withValues(alpha: 0.70)
          : live
          ? green.withValues(alpha: 0.35)
          : away
          ? AppColors.amber.withValues(alpha: 0.40)
          : AppColors.border,
      width: talking ? 1.5 : 1,
    ),
    boxShadow: [
      BoxShadow(
        color: green.withValues(alpha: talking ? 0.16 : 0.0),
        blurRadius: 18,
        spreadRadius: 1,
      ),
    ],
  );
}

/// The face, with a green ring drawn around it while that person talks.
///
/// While they are away the face dims and an amber ring breathes slowly around
/// it: the seat is kept, and the Room is waiting. The breath is an ambient
/// loop, so it holds still under reduced motion.
class _TalkingFace extends StatefulWidget {
  const _TalkingFace({
    required this.talking,
    required this.child,
    this.away = false,
  });

  final bool talking;
  final bool away;
  final Widget child;

  @override
  State<_TalkingFace> createState() => _TalkingFaceState();
}

class _TalkingFaceState extends State<_TalkingFace>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncBreath();
  }

  @override
  void didUpdateWidget(_TalkingFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.away != widget.away) _syncBreath();
  }

  void _syncBreath() {
    if (widget.away) {
      _breath.loopUnlessReduced(context, reverse: true, rest: 1);
    } else if (_breath.isAnimating || _breath.value != 0) {
      _breath.stop();
      _breath.value = 0;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final face = AnimatedOpacity(
      duration: AppMotion.card,
      curve: AppMotion.easeOut,
      opacity: widget.away ? 0.45 : 1,
      child: widget.child,
    );
    return AnimatedBuilder(
      animation: _breath,
      child: face,
      builder: (context, child) {
        final amber = AppColors.amber.withValues(
          alpha: 0.25 + 0.5 * Curves.easeInOut.transform(_breath.value),
        );
        return AnimatedContainer(
          duration: AppMotion.chip,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.talking
                  ? AppColors.green
                  : widget.away
                  ? amber
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: child,
        );
      },
    );
  }
}

/// Moving bars and the TX tag, shown only while a member is talking.
class _TalkingMark extends StatelessWidget {
  const _TalkingMark({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final green = AppColors.green;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const RepaintBoundary(child: WaveformBars()),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: green.withAlpha(40),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: green.withAlpha(100)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: green,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
            ),
          ),
        ),
      ],
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
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.loopUnlessReduced(context, reverse: true);
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
