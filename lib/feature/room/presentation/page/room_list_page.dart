import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/diagnostics/screen_log.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/motion/solid_sheet_route.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/router/route_exit.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../../core/widget/monogram_mark.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';
import '../widget/room_archive_sheet.dart';
import '../widget/room_actions_sheet.dart';
import '../widget/room_dissolve.dart';
import '../widget/room_visuals.dart';
import 'room_create_page.dart';
import '../../../../core/utils/localized_digits_formatter.dart';

/// Offline-first manager for durable Rooms.
///
/// This page intentionally does not start Wi-Fi, a hotspot, Bluetooth or a
/// guest link merely by viewing/selecting a Room. Transport orchestration begins
/// only when the user presses the explicit Start Ride action for the selected
/// durable Room.
class RoomListPage extends StatefulWidget {
  static Widget buildPage() => BlocProvider<RoomListCubit>(
    create: (_) => GetIt.instance<RoomListCubit>()..load(),
    child: const RoomListPage._(),
  );

  const RoomListPage._();

  @override
  State<RoomListPage> createState() => _RoomListPageState();
}

class _RoomListPageState extends State<RoomListPage> {
  @override
  Widget build(BuildContext context) {
    return RouteExitScope(
      onExit: () => _leave(context),
      child: _scaffold(context),
    );
  }

  /// Where "out" is from the saved rooms.
  ///
  /// Explicit, and always present. `AppBar` only draws a back button when the
  /// navigator has something to pop, and this page is routinely reached by a
  /// `go` — leaving the lobby lands here by replacing the stack — so the
  /// control silently vanished after a round trip through a room, and the
  /// system gesture closed the app. Landing is the surface this list belongs
  /// under, so that is where an empty stack goes.
  void _leave(BuildContext context) =>
      exitRouteTo(context, AppRoutes.landingPath);

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      // A deleted Room's card turns to dust; the host keeps its slot open
      // while that plays. See [RoomDissolveHost].
      body: RoomDissolveHost(
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(onBack: () => _leave(context)),
              Expanded(
                child: BlocBuilder<RoomListCubit, RoomListState>(
                  builder: (context, state) {
                    // These four are the same region of the screen showing different
                    // answers, so they dissolve into one another instead of cutting.
                    // A spinner that vanishes and a list that appears in the same frame
                    // reads as two screens; a 220ms crossfade reads as one screen
                    // finishing its sentence.
                    return AnimatedSwitcher(
                      duration: AppMotion.card,
                      switchInCurve: AppMotion.easeOut,
                      switchOutCurve: AppMotion.leaving,
                      // Every state occupies the same fixed slot, so an empty state and
                      // a full list never fight over the height for the length of the
                      // fade, and only the arriving one can be tapped.
                      //
                      // The slots are keyed off the child, and the *shape* of a slot is
                      // identical whether it is arriving or leaving. That is load
                      // bearing: `AnimatedSwitcher` hands this builder widgets carrying
                      // a stable `KeyedSubtree` key, and wrapping only the outgoing
                      // ones — which is the obvious way to write this — changes the
                      // widget at that slot the instant the swap happens, so the
                      // departing subtree is torn down and rebuilt from nothing. It
                      // then replays its own entrance while the switcher is fading it
                      // out: the list you just emptied fades *in* over 335ms on top of
                      // a 220ms fade out, which is the two-step this used to show
                      // after deleting the last Room.
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          for (final child in previous)
                            _slot(child, leaving: true),
                          if (current != null) _slot(current, leaving: false),
                        ],
                      ),
                      child: _body(context, state),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One state of the body, in the slot every state shares.
  ///
  /// [leaving] only ever changes a flag — never the widgets around the child —
  /// so a state that starts arriving and ends up leaving keeps the element it
  /// was built with, and with it its scroll offset and its entrance.
  static Widget _slot(Widget child, {required bool leaving}) => Positioned.fill(
    key: ValueKey<Object?>(child.key),
    child: IgnorePointer(ignoring: leaving, child: child),
  );

  /// Whether the empty state about to show came out of the last Room's dust,
  /// rather than being what the page opened on.
  bool _emptiedByDissolve = false;

  Widget _body(BuildContext context, RoomListState state) {
    final host = RoomDissolveHost.of(context);
    // While the last Room's dust is still in the air the list stays: its slot
    // closes and the card under it is pulled up, in the list it belonged to.
    // The empty state is held until that has settled, then rises out of it —
    // swapping it in at once cut it in over the dust.
    final settling = host?.isSettling ?? false;
    if (!settling) {
      if (state.loading && state.rooms.isEmpty) {
        return const Center(
          key: ValueKey('rooms-loading'),
          child: CircularProgressIndicator(),
        );
      }
      if (state.error != null && state.rooms.isEmpty) {
        return _ErrorState(
          key: const ValueKey('rooms-error'),
          onRetry: context.read<RoomListCubit>().load,
        );
      }
      if (state.rooms.isEmpty) {
        return _EmptyState(
          key: const ValueKey('rooms-empty'),
          afterDissolve: _emptiedByDissolve,
          onCreate: () => _createRoom(context),
        );
      }
    }
    _emptiedByDissolve = settling && state.rooms.isEmpty;
    // A Room that was just deleted stays in its place, invisible, while its
    // slot closes; the count above already says the true number.
    final rooms = host?.retain(state.rooms, (s) => s.room.id) ?? state.rooms;
    return RefreshIndicator(
      key: const ValueKey('rooms-list-view'),
      onRefresh: context.read<RoomListCubit>().load,
      child: StaggeredEntrance(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: _gap),
            child: _SectionLabel(
              text: context.getString.rooms_section(
                state.rooms.length.localized(context),
              ),
            ),
          ),
          for (final saved in rooms)
            // The gap below each card belongs to the card, so a deleted one
            // takes its gap with it as it closes.
            RoomDissolvable(
              id: saved.room.id,
              gap: _gap,
              child: _RoomCard(
                saved: saved,
                selected: state.selectedRoomId == saved.room.id,
                busy: state.loading,
                onOpen: () {
                  ScreenLog.tap('OpenRoom');
                  _openRoom(context, saved);
                },
                onRename: () => _renameRoom(context, saved),
                onArchive: () => _archiveRoom(context, saved),
                onLeave: () => _leaveRoom(context, saved),
                onDelete: () => confirmAndDeleteRoom(context, saved),
              ),
            ),
          // Creation sits where the lobby keeps Invite: under the list, a
          // quieter card than the Room in play. A floating button covered the
          // last card's menu and was the one Material-default shape left.
          // Pulled up with the Rooms when one above it is deleted.
          RoomDissolveFollower(
            child: _CreateAction(
              key: const Key('rooms-create-fab'),
              label: context.getString.rooms_new_room,
              onTap: () => _createRoom(context),
            ),
          ),
        ],
        builder: (context, children) => ListView.builder(
          key: const Key('rooms-list'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          itemCount: children.length,
          itemBuilder: (context, index) => children[index],
        ),
      ),
    );
  }

  /// Space between the list's items. Carried by each item rather than by
  /// separators, so a row closing takes its own space away with it.
  static const double _gap = 12;

  Future<void> _createRoom(BuildContext context) async {
    ScreenLog.tap('NewRoom');
    final cubit = context.read<RoomListCubit>();
    // The sheet hands over straight to the lobby: going there while the sheet
    // is still on top slides the lobby in over it, instead of first dropping
    // the sheet back down onto this list for a beat.
    void enterRoom(SavedRoom _) => context.go(AppRoutes.walkiePath);
    final created = await Navigator.of(context).push<SavedRoom>(
      SolidSheetRoute(
        settings: const RouteSettings(name: 'RoomCreatePage'),
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: RoomCreatePage(onCreated: enterRoom),
        ),
      ),
    );
    if (created != null && context.mounted) {
      context.go(AppRoutes.walkiePath);
    }
  }

  /// Selects the Room and opens its lobby. Nothing connects until Start is
  /// pressed there.
  Future<void> _openRoom(BuildContext context, SavedRoom saved) async {
    await context.read<RoomListCubit>().select(saved.room.id);
    if (context.mounted) context.go(AppRoutes.walkiePath);
  }

  Future<void> _renameRoom(BuildContext context, SavedRoom saved) async {
    final name = await _nameDialog(
      context,
      title: context.getString.rooms_rename,
      action: context.getString.rooms_save,
      hint: context.getString.rooms_name_hint,
      initialValue: saved.room.name,
    );
    if (name == null || !context.mounted) return;
    await context.read<RoomListCubit>().rename(saved.room.id, name);
  }

  Future<void> _archiveRoom(BuildContext context, SavedRoom saved) async {
    final confirmed = await showConfirmSheet(
      context,
      title: context.getString.rooms_archive,
      body: context.getString.rooms_archive_confirm(saved.room.name),
      action: context.getString.rooms_archive,
      icon: Icons.inventory_2_outlined,
    );
    if (confirmed && context.mounted) {
      await context.read<RoomListCubit>().archive(saved.room.id);
    }
  }

  Future<void> _leaveRoom(BuildContext context, SavedRoom saved) async {
    final confirmed = await showConfirmSheet(
      context,
      title: context.getString.rooms_leave,
      body: context.getString.rooms_leave_confirm(saved.room.name),
      action: context.getString.rooms_leave,
      icon: Icons.logout_rounded,
      destructive: true,
    );
    if (confirmed && context.mounted) {
      await context.read<RoomListCubit>().leave(saved.room.id);
    }
  }

  static Future<String?> _nameDialog(
    BuildContext context, {
    required String title,
    required String action,
    required String hint,
    String initialValue = '',
  }) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      routeSettings: const RouteSettings(name: 'RoomNameDialog'),
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('room-name-field'),
          controller: controller,
          autofocus: true,
          maxLength: 48,
          buildCounter: localizedCounter(),
          inputFormatters: [LocaleDigitsFormatter.of(context)],
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.getString.rooms_cancel),
          ),
          FilledButton(
            key: const Key('room-name-submit'),
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
            },
            child: Text(action),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// One saved Room, drawn the way the lobby draws it.
///
/// The members are faces rather than a count on a grey monogram, so the list
/// reads as *who* each Room is before what it is called. The Room in play is
/// lit like the lobby's hero — a warm glow from above and an amber rim.
///
/// One tap opens the Room's lobby. Starting the connection happens there and
/// only there; a Start button here only ever opened the lobby under a label
/// that promised more.
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.saved,
    required this.selected,
    required this.busy,
    required this.onOpen,
    required this.onRename,
    required this.onArchive,
    required this.onLeave,
    required this.onDelete,
  });

  final SavedRoom saved;
  final bool selected;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  static final _radius = BorderRadius.circular(24);

  @override
  Widget build(BuildContext context) {
    // Confirmed, not active: an unused invite holds a durable seat and must
    // not be counted as a person who is in the room.
    final confirmed = saved.room.confirmedMembers;
    final members = confirmed.length;
    final pending = saved.room.pendingMembers.length;
    final archived = saved.room.archived;
    final lit = selected && !archived;
    final accent = lit ? AppColors.amber : AppColors.textSecondary;

    return Semantics(
      selected: selected,
      button: !archived,
      label: _roomSemantics(context, saved.room.name, members, selected),
      explicitChildNodes: true,
      child: PressableScale(
        key: Key('room-${saved.room.id.value}'),
        // The card is the control: one tap opens this Room's lobby.
        onTap: busy || archived ? null : onOpen,
        borderRadius: _radius,
        child: AnimatedContainer(
          // Rim, glow and wash all travel together on one curve, so selecting
          // reads as the card lighting up rather than being redrawn.
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          decoration: roomCardDecoration(lit: lit, radius: _radius),
          padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 6, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _RoomFacesMark(
                    name: saved.room.name,
                    members: confirmed,
                    archived: archived,
                    lit: lit,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          saved.room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: archived
                                ? AppColors.textSecondary
                                : AppColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        _MetaLine(
                          members: members,
                          pending: pending,
                          archived: archived,
                          canInvite: saved.membership.canManageInvites,
                          accent: accent,
                        ),
                      ],
                    ),
                  ),
                  _RoomMenu(
                    saved: saved,
                    busy: busy,
                    archived: archived,
                    onRename: onRename,
                    onArchive: onArchive,
                    onLeave: onLeave,
                    onDelete: onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who is in the Room, as the lobby shows them: overlapping tinted faces.
///
/// Falls back to the room's monogram when there is nobody confirmed to draw,
/// and to the archive mark for an archived Room.
class _RoomFacesMark extends StatelessWidget {
  const _RoomFacesMark({
    required this.name,
    required this.members,
    required this.archived,
    required this.lit,
  });

  final String name;
  final List<RoomMember> members;
  final bool archived;
  final bool lit;

  static const _size = 38.0;

  /// Room for two faces and a "+N" whatever this Room has, so every name in
  /// the list starts at the same place.
  static final _slot = RoomFaces.widthFor(size: _size, slots: 3);

  @override
  Widget build(BuildContext context) => SizedBox(
    width: _slot,
    child: Align(alignment: AlignmentDirectional.centerStart, child: _mark()),
  );

  Widget _mark() {
    if (archived || members.isEmpty) {
      final accent = lit ? AppColors.amber : AppColors.textSecondary;
      return MonogramMark(
        name: name,
        accent: accent,
        strong: lit,
        child: archived
            ? Icon(Icons.archive_rounded, size: 19, color: accent)
            : null,
      );
    }
    // Two faces and a "+N" at most: the name needs the width more than a
    // third face does on a 320px phone.
    return RoomFaces(members: members, size: _size, maxShown: 2);
  }
}

/// Members, held seats and role, on one line that never wraps into the title.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.members,
    required this.pending,
    required this.archived,
    required this.canInvite,
    required this.accent,
  });

  final int members;
  final int pending;
  final bool archived;
  final bool canInvite;
  final Color accent;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => DefaultTextStyle.merge(
      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          _item(
            constraints.maxWidth,
            Icons.person_rounded,
            context.getString.rooms_member_count(members.localized(context)),
            accent,
          ),
          if (pending > 0)
            _item(
              constraints.maxWidth,
              Icons.hourglass_top_rounded,
              _pendingSeats(context, pending),
              AppColors.textSecondary,
            ),
          if (archived)
            Text(
              context.getString.rooms_archived,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            )
          else if (canInvite)
            _item(
              constraints.maxWidth,
              Icons.shield_moon_rounded,
              context.getString.rooms_can_invite,
              accent,
            ),
        ],
      ),
    ),
  );

  /// One icon-and-label pair, capped at the line's own width.
  ///
  /// A `Wrap` hands its children unbounded width, so a `Row` inside one sizes
  /// to its content and overflows rather than wrapping — which is what a long
  /// Persian label did to this line at 320px. The cap gives the label
  /// something finite to ellipsise against.
  Widget _item(double maxWidth, IconData icon, String label, Color tint) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: tint),
            const SizedBox(width: 4),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}

class _RoomMenu extends StatelessWidget {
  const _RoomMenu({
    required this.saved,
    required this.busy,
    required this.archived,
    required this.onRename,
    required this.onArchive,
    required this.onLeave,
    required this.onDelete,
  });

  final SavedRoom saved;
  final bool busy;
  final bool archived;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => IconButton(
    key: Key('room-menu-${saved.room.id.value}'),
    tooltip: context.getString.rooms_manage,
    style: IconButton.styleFrom(
      foregroundColor: AppColors.textSecondary,
      backgroundColor: AppColors.fieldCard.withValues(alpha: 0.72),
      minimumSize: const Size(44, 44),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.border.withValues(alpha: 0.65)),
      ),
    ),
    icon: const Icon(Icons.more_horiz_rounded, size: 20),
    onPressed: busy
        ? null
        : () async {
            final action = await showRoomActionsSheet(
              context,
              roomName: saved.room.name,
              archived: archived,
            );
            if (!context.mounted || action == null) return;
            ScreenLog.tap('RoomMenu ${action.name}');
            switch (action) {
              case RoomAction.rename:
                onRename();
              case RoomAction.archive:
                onArchive();
              case RoomAction.leave:
                onLeave();
              case RoomAction.delete:
                onDelete();
            }
          },
  );
}

/// Way into the archive, carrying how much is in it.
///
/// A count rather than a bare icon: the whole failure this replaces was
/// archived Rooms being invisible, and an unlabelled icon would only have made
/// them one tap less invisible.
class _ArchiveAction extends StatelessWidget {
  const _ArchiveAction({
    required this.count,
    required this.label,
    required this.countLabel,
    required this.onTap,
    super.key,
  });

  final int count;
  final String label;
  final String countLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$label, $countLabel',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.textSecondary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: AppColors.textSecondary.withValues(alpha: 0.4),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  countLabel,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The page with no Rooms on it, and how it arrives.
///
/// After the last Room is deleted it does not cut in: it is assembled out of
/// that Room's dust. The hero card rises into the space the list left and
/// settles; the embers still drifting up from the dissolve are drawn back
/// down into the ring and light it; the ring's mark swells in on the flash;
/// then the words and the button follow, one beat apart. One controller for
/// all of it, read through intervals — the same budget as any entrance.
///
/// Opened on an already empty list it plays the same rise without the
/// embers, which belong to a deletion. Reduced motion keeps the order and the
/// fades and drops the travel and the sparks.
class _EmptyState extends StatefulWidget {
  const _EmptyState({
    required this.onCreate,
    this.afterDissolve = false,
    super.key,
  });

  final VoidCallback onCreate;

  /// Whether this follows the last Room turning to dust.
  final bool afterDissolve;

  @override
  State<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<_EmptyState>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: widget.afterDissolve
        ? const Duration(milliseconds: 950)
        : const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    _entrance.forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Animation<double> _span(double begin, double end, [Curve? curve]) =>
      CurvedAnimation(
        parent: _entrance,
        curve: Interval(begin, end, curve: curve ?? AppMotion.easeOut),
      );

  /// Fades [child] in over [begin]..[end] of the entrance, rising [rise]
  /// logical pixels into place.
  Widget _arrive(
    Widget child, {
    required double begin,
    required double end,
    required double rise,
    required bool reduced,
  }) {
    final t = _span(begin, end);
    final faded = FadeTransition(opacity: t, child: child);
    if (reduced) return faded;
    return AnimatedBuilder(
      animation: t,
      child: faded,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, rise * (1 - t.value)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final sparks = widget.afterDissolve && !reduced;
    // The card's own rise is longer and softer than its contents': it is the
    // ground everything else lands on.
    final card = _span(0, 0.6);
    final ring = _span(sparks ? 0.26 : 0.12, sparks ? 0.58 : 0.5);
    final mark = _span(
      sparks ? 0.3 : 0.14,
      sparks ? 0.64 : 0.55,
      Curves.easeOutBack,
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The lobby's hero, before there is anyone in it.
              AnimatedBuilder(
                animation: card,
                builder: (context, child) => Opacity(
                  opacity: card.value.clamp(0.0, 1.0),
                  child: reduced
                      ? child
                      : Transform.translate(
                          offset: Offset(0, 26 * (1 - card.value)),
                          child: Transform.scale(
                            scale: 0.95 + 0.05 * card.value,
                            child: child,
                          ),
                        ),
                ),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                  decoration: roomCardDecoration(
                    lit: true,
                    radius: BorderRadius.circular(28),
                  ),
                  child: Column(
                    children: [
                      _IgnitingRing(
                        ring: ring,
                        mark: mark,
                        embers: sparks ? _span(0, 0.46) : null,
                        reduced: reduced,
                      ),
                      const SizedBox(height: 18),
                      _arrive(
                        Text(
                          context.getString.rooms_empty_title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                        ),
                        begin: sparks ? 0.38 : 0.22,
                        end: sparks ? 0.78 : 0.7,
                        rise: 10,
                        reduced: reduced,
                      ),
                      const SizedBox(height: 8),
                      _arrive(
                        Text(
                          context.getString.rooms_empty_body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        begin: sparks ? 0.44 : 0.28,
                        end: sparks ? 0.84 : 0.78,
                        rise: 10,
                        reduced: reduced,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _arrive(
                RoomStartButton(
                  key: const Key('rooms-empty-create'),
                  label: context.getString.rooms_create,
                  icon: Icons.add_rounded,
                  breathe: false,
                  onTap: widget.onCreate,
                ),
                begin: sparks ? 0.5 : 0.36,
                end: 1,
                rise: 16,
                reduced: reduced,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The empty state's ring, lit by the embers of the Room that was just
/// deleted.
///
/// [embers] carries a dozen amber specks — the same squares, the same warm
/// glow, as the dust — in from above, where the dissolve sent them, and lands
/// them on the ring. The ring's glow flashes as they arrive ([ring]) and
/// settles to the lit rim it keeps; the mark inside swells in on the flash
/// ([mark]). All of it one painter and two transforms on the entrance's
/// controller; nothing ticks once it is done.
class _IgnitingRing extends StatelessWidget {
  const _IgnitingRing({
    required this.ring,
    required this.mark,
    required this.embers,
    required this.reduced,
  });

  final Animation<double> ring;
  final Animation<double> mark;
  final Animation<double>? embers;
  final bool reduced;

  static const double _size = 84;

  @override
  Widget build(BuildContext context) {
    final amber = AppColors.amber;
    final disc = AnimatedBuilder(
      animation: ring,
      builder: (context, child) {
        final t = ring.value.clamp(0.0, 1.0);
        // A flash that peaks as the embers land, then eases to the rim's
        // resting glow.
        final flash = math.sin(math.pi * t) * (1 - t * 0.35);
        return Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.card,
            border: Border.all(
              color: amber.withValues(alpha: 0.18 + 0.37 * t),
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: amber.withValues(alpha: 0.05 + 0.4 * flash),
                blurRadius: 18 + 16 * flash,
                spreadRadius: 1 + 3 * flash,
              ),
            ],
          ),
          child: child,
        );
      },
      child: Center(
        child: reduced
            ? FadeTransition(
                opacity: mark,
                child: Icon(Icons.groups_2_rounded, size: 40, color: amber),
              )
            : ScaleTransition(
                scale: mark,
                child: Icon(Icons.groups_2_rounded, size: 40, color: amber),
              ),
      ),
    );
    final falling = embers;
    if (falling == null) return disc;
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          disc,
          Positioned(
            left: -90,
            right: -90,
            top: -150,
            bottom: -40,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const Key('rooms-empty-embers'),
                  painter: _EmberPainter(
                    progress: falling,
                    tint: amber,
                    // The ring's centre, inside the painter's box.
                    target: const Offset(90 + _size / 2, 150 + _size / 2),
                    radius: _size / 2,
                    fromRight: Directionality.of(context) == TextDirection.ltr,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Embers falling back into the ring. Deterministic: every speck's path is a
/// function of the progress alone, so the painter holds no state.
class _EmberPainter extends CustomPainter {
  _EmberPainter({
    required this.progress,
    required this.tint,
    required this.target,
    required this.radius,
    required this.fromRight,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color tint;
  final Offset target;
  final double radius;

  /// The dust drifted toward the trailing edge; the embers come back from
  /// that side.
  final bool fromRight;

  static const _count = 16;
  final _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t <= 0 || t >= 1) return;
    final hot = Color.lerp(tint, const Color(0xFFFFFFFF), 0.18)!;
    final drift = fromRight ? 1.0 : -1.0;
    for (var i = 0; i < _count; i++) {
      // A fixed scatter, staggered so they land one after another.
      final seed = (i * 0.618034) % 1;
      final start = 0.28 * seed;
      final p = ((t - start) / 0.72).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      // Where each one lands on the ring, spread over its upper arc.
      final landAngle = -math.pi / 2 + (seed - 0.5) * math.pi * 1.25;
      final land =
          target + Offset(math.cos(landAngle), math.sin(landAngle)) * radius;
      // Where it starts: up and off towards the side the dust was carried.
      final from =
          target +
          Offset(
            drift * (30 + 70 * ((i * 0.37) % 1)) * (i.isEven ? 1 : 0.4),
            // No higher than the card's top edge: the page scrolls, and
            // its viewport clips anything above it.
            -(48 + 34 * ((i * 0.53) % 1)),
          );
      // Eases in on a slight arc, like something settling rather than shot.
      final e = AppMotion.easeOut.transform(p);
      final arc = math.sin(math.pi * e) * 14 * drift;
      final at = Offset.lerp(from, land, e)! + Offset(arc, 0);
      final fade = p < 0.2 ? p / 0.2 : (1 - p) / 0.8;
      final half = 3.4 * (1 - 0.45 * e);
      _paint.color = tint.withValues(alpha: 0.85 * fade);
      canvas.drawRect(
        Rect.fromCenter(center: at, width: half * 2, height: half * 2),
        _paint,
      );
      _paint.color = hot.withValues(alpha: 0.9 * fade);
      canvas.drawRect(
        Rect.fromCenter(center: at, width: half, height: half),
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EmberPainter old) =>
      old.progress != progress || old.target != target;
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry, super.key});
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline_rounded, size: 36, color: AppColors.amber),
            const SizedBox(height: 12),
            Text(
              context.getString.rooms_load_error,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(context.getString.rooms_retry),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The lobby's top row: a quiet back arrow that points the reading
/// direction's way, the title, and the archive when there is one.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 12, 4),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: s.rooms_back,
            child: IconButton(
              key: const Key('rooms-back'),
              tooltip: s.rooms_back,
              onPressed: () {
                HapticFeedback.selectionClick();
                onBack();
              },
              icon: Icon(
                // Mirrors itself in right-to-left (matchTextDirection), so it
                // already points the way back in Persian.
                Icons.arrow_back_rounded,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              s.rooms_title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          // Absent until there is something in it. A permanent control for an
          // empty archive is a promise of content the user does not have.
          BlocBuilder<RoomListCubit, RoomListState>(
            buildWhen: (p, c) => p.archived.length != c.archived.length,
            builder: (context, state) => AnimatedSwitcher(
              duration: AppMotion.chip,
              child: state.archived.isEmpty
                  ? const SizedBox(key: ValueKey('rooms-archive-none'))
                  : _ArchiveAction(
                      key: const Key('rooms-archive-action'),
                      count: state.archived.length,
                      label: s.rooms_archived_rooms,
                      countLabel: state.archived.length.localized(context),
                      onTap: () => showRoomArchiveSheet(context),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The lobby's section heading ("Room members (3)"), for the list.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4, top: 8, bottom: 2),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w800,
        fontSize: 12.5,
        letterSpacing: 0.6,
      ),
    ),
  );
}

/// "New room", in the shape of the lobby's secondary actions.
class _CreateAction extends StatelessWidget {
  const _CreateAction({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  static final _radius = BorderRadius.circular(18);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: PressableScale(
      onTap: onTap,
      borderRadius: _radius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: _radius,
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, color: AppColors.amber, size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14.5,
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

/// English pluralises an open seat and Persian does not, so this is two
/// strings rather than one with a suffix glued on. The count is rendered in
/// the reader's own numerals first — a quantity, unlike a room code.
String _pendingSeats(BuildContext context, int count) {
  final n = count.localized(context);
  return count == 1
      ? context.getString.rooms_pending_seat_one(n)
      : context.getString.rooms_pending_seats_other(n);
}

/// Two strings again, because "selected" is a clause a screen reader hears at
/// the end of a sentence rather than a word to append to one.
String _roomSemantics(
  BuildContext context,
  String name,
  int count,
  bool selected,
) {
  final n = count.localized(context);
  return selected
      ? context.getString.rooms_room_semantics_selected(name, n)
      : context.getString.rooms_room_semantics(name, n);
}
