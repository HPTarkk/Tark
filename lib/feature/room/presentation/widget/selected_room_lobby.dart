import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../transfer/api/transfer_api.dart';
import '../../domain/entity/room.dart';
import '../../domain/repository/room_repository.dart';
import '../room_member_display_name.dart';
import 'one_scan_room_invite_sheet.dart';
import 'room_connection_status_chip.dart';
import 'room_connection_status_scope.dart';
import 'room_visuals.dart';

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
    this.onUseHomeWifi,
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

  /// Start over the Wi-Fi network this phone is already on, instead of the
  /// phones' own connection. Offered only when the caller sees one: a home
  /// router is never used unless somebody asks for it here.
  final VoidCallback? onUseHomeWifi;
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
    final showFailure =
        !_connecting && failureMessage != null && failureMessage.isNotEmpty;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: StaggeredEntrance(
          builder: (context, children) => ListView(
            key: const Key('selected-room-lobby'),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: children,
          ),
          children: [
            _LobbyTopBar(
              title: _room.room.name,
              backLabel: s.lobby_back,
              onBack: () {
                HapticFeedback.selectionClick();
                widget.onBack();
              },
            ),
            _LobbyHero(
              heading: _connecting
                  ? s.connecting
                  : alone
                  ? s.lobby_alone_heading
                  : s.lobby_heading,
              hint: _connecting
                  ? s.lobby_connecting_hint
                  : s.lobby_nothing_started,
              members: confirmedMembers,
              connecting: _connecting,
            ),
            // The callout slides in and out rather than shoving the roster
            // down in one frame.
            AnimatedSwitcher(
              duration: AppMotion.card,
              switchInCurve: AppMotion.easeOut,
              switchOutCurve: AppMotion.leaving,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  alignment: AlignmentDirectional.topStart,
                  child: child,
                ),
              ),
              child: showFailure
                  ? Padding(
                      key: ValueKey(failureMessage),
                      padding: const EdgeInsets.only(top: 14),
                      child: _FailureCallout(
                        message: failureMessage,
                        onRetry: widget.onRetry,
                        onConnect: widget.onConnect,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 18),
            _MembersCard(
              room: _room,
              members: confirmedMembers,
              connectionPhase: widget.connectionPhase,
            ),
            const SizedBox(height: 20),
            if (canInvite)
              // Invite sits above Start: adding someone comes before starting.
              Padding(
                padding: EdgeInsets.only(bottom: alone ? 0 : 20),
                child: _RoomAction(
                  key: const Key('selected-room-invite-callout'),
                  icon: Icons.person_add_alt_1_rounded,
                  label: s.lobby_invite_people,
                  primary: alone,
                  enabled: !_connecting,
                  onTap: _invite,
                ),
              )
            else if (alone)
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
            // Start needs somebody to start with. Offering it to a Room of one
            // only ever produced a failure explaining that nobody answered.
            if (!alone)
              Center(
                child: RoomConnectButton(
                  key: const Key('selected-room-start-ride'),
                  label: _connecting ? s.connecting : s.lobby_start_ride,
                  busy: _connecting,
                  onTap: _startRide,
                ),
              ),
            if (!alone && !_connecting && widget.onUseHomeWifi != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Center(
                  child: TextButton.icon(
                    key: const Key('selected-room-use-home-wifi'),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      widget.onUseHomeWifi!();
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    icon: const Icon(Icons.wifi_rounded, size: 18),
                    label: Text(s.lobby_use_home_wifi),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LobbyTopBar extends StatelessWidget {
  const _LobbyTopBar({
    required this.title,
    required this.backLabel,
    required this.onBack,
  });

  final String title;
  final String backLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          key: const Key('selected-room-lobby-back'),
          tooltip: backLabel,
          onPressed: onBack,
          icon: Icon(
            // Mirrors itself in right-to-left (matchTextDirection), so it
            // already points the way back in Persian.
            Icons.arrow_back_rounded,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// The top of the lobby: who is in this Room, drawn as faces rather than a
/// list header, with the one line that says what happens next.
class _LobbyHero extends StatelessWidget {
  const _LobbyHero({
    required this.heading,
    required this.hint,
    required this.members,
    required this.connecting,
  });

  final String heading;
  final String hint;
  final List<RoomMember> members;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      // The signal rings ripple out to the card's edge and stop there.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: amber.withValues(alpha: 0.28)),
        gradient: RadialGradient(
          center: const Alignment(0, -0.6),
          radius: 1.2,
          colors: [
            amber.withValues(alpha: 0.20),
            AppColors.surface.withValues(alpha: 0.0),
          ],
        ),
        color: AppColors.surface,
      ),
      child: Column(
        children: [
          SizedBox(
            height: 92,
            child: _SignalRings(
              active: connecting,
              child: RoomFaces(members: members),
            ),
          ),
          const SizedBox(height: 18),
          AnimatedSwitcher(
            duration: AppMotion.card,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: Text(
              heading,
              key: ValueKey(heading),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: AppMotion.card,
            switchInCurve: AppMotion.easeOut,
            switchOutCurve: AppMotion.leaving,
            child: Text(
              hint,
              key: ValueKey(hint),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft rings travelling outward from the faces while the phones look for
/// each other: the one visual cue that something is happening between them.
/// Nothing moves when idle, and reduced motion keeps a single still ring.
class _SignalRings extends StatefulWidget {
  const _SignalRings({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_SignalRings> createState() => _SignalRingsState();
}

class _SignalRingsState extends State<_SignalRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.pulse,
  );

  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(_SignalRings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _sync();
  }

  void _sync() {
    if (widget.active && !_reduced) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: widget.active
          ? _RingsPainter(
              progress: _controller,
              color: AppColors.amber,
              still: _reduced,
            )
          : null,
      child: Center(child: widget.child),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.progress,
    required this.color,
    required this.still,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.height / 2;
    final reach = size.width / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    if (still) {
      paint.color = color.withValues(alpha: 0.35);
      canvas.drawCircle(center, base + 8, paint);
      return;
    }
    // Three rings a third of a cycle apart, each easing out as it widens.
    for (var i = 0; i < 3; i++) {
      final t = (progress.value + i / 3) % 1.0;
      final eased = AppMotion.easeOut.transform(t);
      final radius = base + (reach - base) * eased;
      paint.color = color.withValues(alpha: 0.45 * (1 - t));
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.still != still;
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
          borderRadius: BorderRadius.circular(18),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 10),
          child: Text(
            s.lobby_members(members.length.localized(context)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              letterSpacing: 0.6,
            ),
          ),
        ),
        for (var index = 0; index < members.length; index++) ...[
          _MemberRow(
            member: members[index],
            isYou: members[index].id == room.membership.localMemberId,
            phase: connectionPhase,
          ),
          if (index != members.length - 1) const SizedBox(height: 8),
        ],
      ],
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            MemberAvatar(member: member, size: 42),
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
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  // Status sits under the name, so a long name and a long
                  // status never compete for one line on a narrow phone.
                  AnimatedSize(
                    duration: AppMotion.chip,
                    curve: AppMotion.easeOut,
                    alignment: AlignmentDirectional.topStart,
                    child: AnimatedSwitcher(
                      duration: AppMotion.chip,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.leaving,
                      child: showStatus
                          ? Padding(
                              key: ValueKey(phase),
                              padding: const EdgeInsets.only(top: 4),
                              child: RoomConnectionStatusChip(phase: phase),
                            )
                          : const SizedBox(
                              key: ValueKey('none'),
                              width: double.infinity,
                            ),
                    ),
                  ),
                ],
              ),
            ),
            if (isYou) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  context.getString.people_you,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
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

class _RoomAction extends StatelessWidget {
  const _RoomAction({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  /// No taps, without claiming to be the thing in progress.
  final bool enabled;

  static final _radius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) {
    final accent = primary ? AppColors.amber : AppColors.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.5,
        duration: AppMotion.chip,
        curve: AppMotion.easeOut,
        child: PressableScale(
          onTap: enabled ? onTap : null,
          borderRadius: _radius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: primary
                  ? AppColors.amber.withValues(alpha: 0.12)
                  : AppColors.surface,
              borderRadius: _radius,
              border: Border.all(
                color: primary ? AppColors.amber : AppColors.border,
                width: primary ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: accent, size: 21),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 14.5,
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
