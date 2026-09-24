import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';
import '../../domain/repository/room_repository.dart';
import '../room_member_display_name.dart';
import 'one_scan_room_invite_sheet.dart';
import 'room_connection_status_chip.dart';
import 'room_connection_status_scope.dart';

/// The durable Room lobby.
///
/// Membership and connection are deliberately separate here. Reserved invite
/// seats remain internal authorization bookkeeping; only confirmed members are
/// shown in the roster. Pressing Start moves that same visible roster to
/// connecting. No carrier role, address, network name or credential appears in
/// the normal Room flow — manual connection is offered only beside a failure
/// the automatic path could not get past.
class SelectedRoomLobby extends StatefulWidget {
  const SelectedRoomLobby({
    required this.room,
    required this.onStartRide,
    required this.onBack,
    this.connectionPhase = RoomConnectionUiPhase.readyToConnect,
    this.failureMessage,
    this.onRetry,
    this.link,
    this.mode,
    this.onConnect,
    this.repository,
    super.key,
  });

  final SavedRoom room;
  final VoidCallback onStartRide;
  final VoidCallback onBack;
  final RoomConnectionUiPhase connectionPhase;

  /// Safe, localized explanation for the most recent failed Start attempt.
  /// Technical transport details and credentials never belong here.
  final String? failureMessage;
  final VoidCallback? onRetry;

  /// Legacy composition seams. They intentionally do not drive normal lobby
  /// copy or actions; transport is an implementation detail here.
  final LiveLink? link;
  final TransferMode? mode;

  /// Connecting the phones by hand. Shown only inside the failure callout,
  /// and only for failures the caller says it can help with.
  final VoidCallback? onConnect;
  final RoomRepository? repository;

  @override
  State<SelectedRoomLobby> createState() => _SelectedRoomLobbyState();
}

class _SelectedRoomLobbyState extends State<SelectedRoomLobby> {
  late SavedRoom _room = widget.room;
  StreamSubscription<void>? _changes;

  RoomRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    return GetIt.instance.isRegistered<RoomRepository>()
        ? GetIt.instance<RoomRepository>()
        : null;
  }

  bool get _connecting =>
      widget.connectionPhase == RoomConnectionUiPhase.connecting;

  @override
  void initState() {
    super.initState();
    _changes = _repository?.changes.listen((_) {
      if (mounted) unawaited(_reload());
    });
  }

  @override
  void didUpdateWidget(SelectedRoomLobby oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.room.room.id != widget.room.room.id) {
      _room = widget.room;
    }
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final repository = _repository;
    if (repository == null) return;
    final SavedRoom? next;
    try {
      next = await repository.get(_room.room.id);
    } catch (_) {
      // Keep the last durable snapshot. A transient storage read is not a
      // useful error to put in front of somebody about to ride.
      return;
    }
    if (next == null || !mounted) return;
    setState(() => _room = next!);
  }

  Future<void> _invite() async {
    HapticFeedback.selectionClick();
    final before = {
      for (final member in _room.room.confirmedMembers) member.id,
    };
    final arrived = await showOneScanRoomInviteSheet(
      context,
      repository: widget.repository,
    );
    await _reload();
    if (!mounted) return;
    // Somebody scanned and is already connecting from their side. Starting
    // here too is the host's half of "they come straight in" — also when the
    // sheet was swiped away during the "joined" beat.
    final joined =
        arrived ||
        _room.room.confirmedMembers.any(
          (member) => !before.contains(member.id),
        );
    if (joined) _startRide();
  }

  void _startRide() {
    if (_connecting) return;
    widget.onStartRide();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final confirmedMembers = _room.room.confirmedMembers;
    final canInvite =
        !_room.room.archived &&
        _room.membership.active &&
        _room.membership.canManageInvites;
    // Pending invite seats are authorization bookkeeping, not joined people.
    // Only confirmed membership can make this Room stop looking solo.
    final alone = confirmedMembers.length <= 1;
    final failureMessage = widget.failureMessage?.trim();

    return Scaffold(
      appBar: AppBar(
        leading: Semantics(
          button: true,
          label: s.lobby_back,
          child: IconButton(
            key: const Key('selected-room-lobby-back'),
            tooltip: s.lobby_back,
            onPressed: () {
              HapticFeedback.selectionClick();
              widget.onBack();
            },
            icon: Icon(
              Icons.arrow_back_rounded,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        title: Text(_room.room.name),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('selected-room-lobby'),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: [
            Text(
              _connecting
                  ? s.connecting
                  : alone
                  ? s.lobby_alone_heading
                  : s.lobby_heading,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              _connecting ? s.lobby_connecting_hint : s.lobby_nothing_started,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            if (!_connecting &&
                failureMessage != null &&
                failureMessage.isNotEmpty) ...[
              const SizedBox(height: 14),
              _FailureCallout(
                message: failureMessage,
                onRetry: widget.onRetry,
                onConnect: widget.onConnect,
              ),
            ],
            const SizedBox(height: 22),
            _MembersCard(
              room: _room,
              members: confirmedMembers,
              connectionPhase: widget.connectionPhase,
            ),
            const SizedBox(height: 18),
            if (canInvite) ...[
              _RoomAction(
                key: const Key('selected-room-invite-callout'),
                icon: Icons.person_add_alt_1_rounded,
                label: s.lobby_invite_people,
                primary: alone,
                enabled: !_connecting,
                onTap: _invite,
              ),
              const SizedBox(height: 12),
            ],
            // Start needs somebody to start with. Offering it to a Room of one
            // only ever produced a failure explaining that nobody answered.
            if (!alone)
              _RoomAction(
                key: const Key('selected-room-start-ride'),
                icon: Icons.play_arrow_rounded,
                label: s.lobby_start_ride,
                primary: true,
                busy: _connecting,
                onTap: _startRide,
              )
            else if (!canInvite)
              Text(
                s.lobby_alone_no_invite,
                key: const Key('selected-room-alone-no-invite'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FailureCallout extends StatelessWidget {
  const _FailureCallout({required this.message, this.onRetry, this.onConnect});

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;
    final connect = onConnect;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const Key('selected-room-start-failure'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 21),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (retry != null || connect != null) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 4,
                      children: [
                        if (retry != null)
                          TextButton.icon(
                            key: const Key('selected-room-retry'),
                            onPressed: retry,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: Text(context.getString.retry),
                          ),
                        if (connect != null)
                          TextButton.icon(
                            key: const Key('selected-room-connect-phones'),
                            onPressed: connect,
                            icon: const Icon(Icons.link_rounded, size: 18),
                            label: Text(context.getString.room_start_connect),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersCard extends StatelessWidget {
  const _MembersCard({
    required this.room,
    required this.members,
    required this.connectionPhase,
  });

  final SavedRoom room;
  final List<RoomMember> members;
  final RoomConnectionUiPhase connectionPhase;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.groups_2_rounded, size: 19, color: AppColors.amber),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  s.lobby_members(members.length.localized(context)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < members.length; index++) ...[
            _MemberRow(
              member: members[index],
              isYou: members[index].id == room.membership.localMemberId,
              phase: connectionPhase,
            ),
            if (index != members.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isYou,
    required this.phase,
  });

  final RoomMember member;
  final bool isYou;
  final RoomConnectionUiPhase phase;

  @override
  Widget build(BuildContext context) {
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: context.getString.people_unnamed,
    );
    // Before Start nothing is known about anybody else's phone, so their row
    // says nothing about it. A "ready" badge here would be a claim about a
    // phone that may still be at home.
    final showStatus = !isYou && phase != RoomConnectionUiPhase.readyToConnect;
    return Semantics(
      container: true,
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.amber.withValues(alpha: 0.12),
              border: Border.all(
                color: AppColors.amber.withValues(alpha: 0.38),
              ),
            ),
            child: Icon(Icons.person_rounded, size: 20, color: AppColors.amber),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                if (isYou) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.getString.people_you,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ] else if (showStatus) ...[
                  const SizedBox(height: 4),
                  RoomConnectionStatusChip(phase: phase),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomAction extends StatelessWidget {
  const _RoomAction({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
    this.busy = false,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  /// Spinner in place of the icon, and no taps: this action is the one in
  /// progress.
  final bool busy;

  /// No taps, without claiming to be the thing in progress.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final accent = primary ? AppColors.amber : AppColors.textSecondary;
    final interactive = enabled && !busy;
    return Semantics(
      button: true,
      enabled: interactive,
      label: label,
      child: Opacity(
        opacity: enabled || busy ? 1 : 0.5,
        child: InkWell(
          onTap: interactive
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            decoration: BoxDecoration(
              color: primary
                  ? AppColors.amber.withValues(alpha: 0.12)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: primary ? AppColors.amber : AppColors.border,
                width: primary ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accent,
                    ),
                  )
                else
                  Icon(icon, color: accent, size: 21),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
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
