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

/// The durable Room lobby.
///
/// This surface deliberately does not explain transport. A rider joined a
/// Room, not a Wi-Fi network, and the connection layer is responsible for
/// preferring a proven shared LAN, raising a Tark hotspot when needed and
/// recovering/failing over without asking the rider to choose Host / Join.
///
/// `link`, `mode` and `onConnect` remain constructor seams while the router is
/// migrated incrementally, but they do not change the primary Room UI. Manual
/// transport controls belong to explicit troubleshooting only.
class SelectedRoomLobby extends StatefulWidget {
  const SelectedRoomLobby({
    required this.room,
    required this.onStartRide,
    required this.onBack,
    this.link,
    this.mode,
    this.onConnect,
    this.repository,
    this.preLiveBootstrap,
    super.key,
  });

  final SavedRoom room;
  final VoidCallback onStartRide;
  final VoidCallback onBack;

  /// Legacy composition seams. They intentionally do not drive normal lobby
  /// copy or actions; transport is an implementation detail here.
  final LiveLink? link;
  final TransferMode? mode;
  final VoidCallback? onConnect;

  final RoomRepository? repository;

  /// Test seam around the hidden transfer bridge. Production deliberately
  /// resolves the real bridge lazily only when an eligible bootstrap host has
  /// no current link at the moment Start is pressed.
  final PreLiveHotspotBootstrap? preLiveBootstrap;

  @override
  State<SelectedRoomLobby> createState() => _SelectedRoomLobbyState();
}

class _SelectedRoomLobbyState extends State<SelectedRoomLobby> {
  late SavedRoom _room = widget.room;
  StreamSubscription<void>? _changes;
  bool _starting = false;

  RoomRepository? get _repository {
    if (widget.repository != null) return widget.repository;
    return GetIt.instance.isRegistered<RoomRepository>()
        ? GetIt.instance<RoomRepository>()
        : null;
  }

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
    try {
      final next = await repository.get(_room.room.id);
      if (next != null && mounted) setState(() => _room = next);
    } catch (_) {
      // Keep the last durable snapshot. A transient storage read is not a
      // useful error to put in front of somebody about to ride.
    }
  }

  bool get _isPreferredBootstrapHost {
    final active = _room.room.activeMembers.toList(growable: false)
      ..sort((a, b) {
        final joined = a.joinedAt.compareTo(b.joinedAt);
        return joined != 0 ? joined : a.id.value.compareTo(b.id.value);
      });
    return active.isNotEmpty &&
        active.first.id == _room.membership.localMemberId;
  }

  bool get _hasReusableRoomHotspot {
    final link = widget.link;
    final mode = widget.mode;
    if (link == null || mode == null) return false;
    return link.isUp && mode == TransferMode.hotspot && link.arranged(mode);
  }

  Future<void> _invite() async {
    HapticFeedback.selectionClick();

    // A current Tark hotspot is reused. Otherwise only the deterministic
    // creator/preferred bootstrap side is allowed to raise one behind the
    // one-scan sheet; Room invite authority is never used to choose a host.
    //
    // Proven shared-LAN selection belongs to the Room transport planner. The
    // pre-live QR cannot treat a local Wi-Fi association as proof that the
    // other phone is reachable, so it never guesses from SSID/interface state.
    await showOneScanRoomInviteSheet(
      context,
      repository: widget.repository,
      bootstrapHost: !_hasReusableRoomHotspot && _isPreferredBootstrapHost,
    );
    await _reload();
  }

  Future<void> _startRide() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final link = widget.link;

      // Do not guess while the first link probe is still unresolved. If Wi-Fi,
      // an existing Tark hotspot, or Bluetooth is already up, the router/live
      // binding gets first use of it and actual peer health decides whether it
      // is viable. That preserves the LAN-first path without treating a local
      // Wi-Fi interface as proof of shared reachability.
      //
      // Once the probe has positively said "no link", only the deterministic
      // preferred bootstrap side may raise Tark's fallback hotspot. The same
      // transfer bridge used by the one-scan invite owns permissions/retries
      // and hands the established attachment to HotspotLinkKeeper. No Host /
      // Join choice or network instructions enter the Room UI.
      if (link != null && !link.isUp && _isPreferredBootstrapHost) {
        await (widget.preLiveBootstrap ?? PreLiveHotspotBootstrap())
            .prepareHost();
      }

      if (!mounted) return;
      widget.onStartRide();
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final members = _room.room.confirmedMembers;
    final canInvite =
        !_room.room.archived &&
        _room.membership.active &&
        _room.membership.canManageInvites;

    // Pending invite seats are authorization bookkeeping, not people. Opening
    // or regenerating a QR must never make the Room look less empty or add a
    // "waiting" person to the primary roster.
    final alone = members.length <= 1;

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
              alone ? s.lobby_alone_heading : s.lobby_heading,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              s.lobby_nothing_started,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            _MembersCard(room: _room, members: members),
            const SizedBox(height: 18),
            if (canInvite) ...[
              _RoomAction(
                key: const Key('selected-room-invite-callout'),
                icon: Icons.person_add_alt_1_rounded,
                label: s.invite_people,
                primary: alone,
                onTap: _invite,
              ),
              const SizedBox(height: 12),
            ],
            _RoomAction(
              key: const Key('selected-room-start-ride'),
              icon: Icons.play_arrow_rounded,
              label: s.lobby_start_ride,
              primary: !alone || !canInvite,
              busy: _starting,
              onTap: _startRide,
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersCard extends StatelessWidget {
  const _MembersCard({required this.room, required this.members});

  final SavedRoom room;
  final List<RoomMember> members;

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
              Text(
                s.people_in_room(members.length.localized(context)),
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < members.length; index++) ...[
            _MemberRow(
              member: members[index],
              isYou: members[index].id == room.membership.localMemberId,
            ),
            if (index != members.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.isYou});

  final RoomMember member;
  final bool isYou;

  @override
  Widget build(BuildContext context) {
    final name = roomMemberDisplayName(
      member,
      fa: Localizations.localeOf(context).languageCode == 'fa',
      unnamed: context.getString.people_unnamed,
    );
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amber.withValues(alpha: 0.12),
            border: Border.all(color: AppColors.amber.withValues(alpha: 0.38)),
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
                const SizedBox(height: 2),
                Text(
                  context.getString.people_you,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
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
    super.key,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final accent = primary ? AppColors.amber : AppColors.textSecondary;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: busy
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
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
    );
  }
}
