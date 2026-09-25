import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/router/route_exit.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/localized_counter.dart';
import '../../../../core/widget/monogram_mark.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';
import '../widget/room_archive_sheet.dart';
import '../widget/room_visuals.dart';

/// Offline-first manager for durable Rooms.
///
/// This page intentionally does not start Wi-Fi, a hotspot, Bluetooth or a
/// guest link merely by viewing/selecting a Room. Transport orchestration begins
/// only when the user presses the explicit Start Ride action for the selected
/// durable Room.
class RoomListPage extends StatefulWidget {
  static Widget buildPage({bool createOnOpen = false}) =>
      BlocProvider<RoomListCubit>(
        create: (_) => GetIt.instance<RoomListCubit>()..load(),
        child: RoomListPage._(createOnOpen: createOnOpen),
      );

  final bool createOnOpen;

  const RoomListPage._({this.createOnOpen = false});

  @override
  State<RoomListPage> createState() => _RoomListPageState();
}

class _RoomListPageState extends State<RoomListPage> {
  bool _autoCreateStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.createOnOpen && !_autoCreateStarted) {
      _autoCreateStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _createRoom(context);
      });
    }
  }

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
      body: SafeArea(
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

  Widget _body(BuildContext context, RoomListState state) {
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
        onCreate: () => _createRoom(context),
      );
    }
    return RefreshIndicator(
      key: const ValueKey('rooms-list-view'),
      onRefresh: context.read<RoomListCubit>().load,
      child: StaggeredEntrance(
        children: [
          _SectionLabel(
            text: context.getString.rooms_section(
              state.rooms.length.localized(context),
            ),
          ),
          for (final saved in state.rooms)
            _RoomCard(
              saved: saved,
              selected: state.selectedRoomId == saved.room.id,
              busy: state.loading,
              onSelect: () =>
                  context.read<RoomListCubit>().select(saved.room.id),
              onStart: state.selectedRoomId == saved.room.id
                  ? () => context.go(AppRoutes.walkiePath)
                  : null,
              onRename: () => _renameRoom(context, saved),
              onArchive: () => _archiveRoom(context, saved),
              onLeave: () => _leaveRoom(context, saved),
              onDelete: () => confirmAndDeleteRoom(context, saved),
            ),
          // Creation sits where the lobby keeps Invite: under the list, a
          // quieter card than the Room in play. A floating button covered the
          // last card's menu and was the one Material-default shape left.
          _CreateAction(
            key: const Key('rooms-create-fab'),
            label: context.getString.rooms_new_room,
            onTap: () => _createRoom(context),
          ),
        ],
        builder: (context, children) => ListView.separated(
          key: const Key('rooms-list'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => children[index],
        ),
      ),
    );
  }

  Future<void> _createRoom(BuildContext context) async {
    final name = await _nameDialog(
      context,
      title: context.getString.rooms_create,
      action: context.getString.rooms_create,
      hint: context.getString.rooms_name_hint,
    );
    if (name == null || !context.mounted) return;

    var localDisplayName = '';
    try {
      localDisplayName = await GetIt.instance<SettingsRepository>().getMyName();
    } catch (_) {
      // Room creation remains available offline even if settings storage is
      // temporarily unavailable. This fallback is local display metadata,
      // never identity or authorization.
    }
    if (!context.mounted) return;
    final created = await context.read<RoomListCubit>().createRoom(
      name: name,
      localDisplayName: localDisplayName.trim().isEmpty
          ? context.getString.rooms_fallback_member_name
          : localDisplayName.trim(),
    );
    if (created != null && context.mounted) {
      context.go(AppRoutes.walkiePath);
    }
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
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('room-name-field'),
          controller: controller,
          autofocus: true,
          maxLength: 48,
          buildCounter: localizedCounter(),
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
/// lit like the lobby's hero — a warm glow from above and an amber rim — and
/// grows the same wide amber Start button underneath, so selecting a card is
/// visibly the first half of the lobby rather than a different screen's idea
/// of it.
///
/// One hierarchy that never moves: faces, the name, one line of metadata, and
/// the menu. Selection adds Start underneath rather than replacing anything,
/// so nothing the user was already looking at jumps.
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.saved,
    required this.selected,
    required this.busy,
    required this.onSelect,
    required this.onStart,
    required this.onRename,
    required this.onArchive,
    required this.onLeave,
    required this.onDelete,
  });

  final SavedRoom saved;
  final bool selected;
  final bool busy;
  final VoidCallback onSelect;
  final VoidCallback? onStart;
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
      excludeSemantics: true,
      child: PressableScale(
        key: Key('room-${saved.room.id.value}'),
        // Tapping an already-selected card starts it. The card is the control;
        // needing a second, differently-shaped button to do the obvious thing
        // is what made the old row feel like a form rather than a list.
        onTap: busy || archived
            ? null
            : selected
            ? onStart
            : onSelect,
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
              // Grows in under the identity rather than swapping with it, so
              // selecting a card never reflows the line the user just read.
              AnimatedSize(
                duration: AppMotion.card,
                curve: AppMotion.easeOut,
                alignment: Alignment.topCenter,
                child: lit
                    ? Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          0,
                          16,
                          10,
                          0,
                        ),
                        // The lobby's own Start, minus the breathing: that
                        // pulse is the lobby's cue that the ride is one tap
                        // away, and on a list it would never settle.
                        child: RoomStartButton(
                          key: Key('room-start-${saved.room.id.value}'),
                          label: context.getString.rooms_start_ride,
                          busy: busy,
                          breathe: false,
                          height: 54,
                          onTap: onStart,
                        ),
                      )
                    : const SizedBox(width: double.infinity),
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
  Widget build(BuildContext context) => PopupMenuButton<_RoomAction>(
    key: Key('room-menu-${saved.room.id.value}'),
    enabled: !busy,
    tooltip: context.getString.rooms_manage,
    iconColor: AppColors.textSecondary,
    iconSize: 20,
    position: PopupMenuPosition.under,
    onSelected: (action) {
      switch (action) {
        case _RoomAction.rename:
          onRename();
        case _RoomAction.archive:
          onArchive();
        case _RoomAction.leave:
          onLeave();
        case _RoomAction.delete:
          onDelete();
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        value: _RoomAction.rename,
        child: Text(context.getString.rooms_rename),
      ),
      if (!archived)
        PopupMenuItem(
          value: _RoomAction.archive,
          child: Text(context.getString.rooms_archive),
        ),
      PopupMenuItem(
        value: _RoomAction.leave,
        child: Text(context.getString.rooms_leave),
      ),
      // Last, and the only coloured item: archive and leave are both
      // recoverable, and this one is not.
      PopupMenuItem(
        value: _RoomAction.delete,
        child: Text(
          context.getString.rooms_delete,
          style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );
}

enum _RoomAction { rename, archive, leave, delete }

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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate, super.key});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The lobby's hero, before there is anyone in it.
            Container(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
              decoration: roomCardDecoration(
                lit: true,
                radius: BorderRadius.circular(28),
              ),
              child: Column(
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.card,
                      border: Border.all(
                        color: AppColors.amber.withValues(alpha: 0.55),
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      Icons.groups_2_rounded,
                      size: 40,
                      color: AppColors.amber,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    context.getString.rooms_empty_title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.getString.rooms_empty_body,
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
            const SizedBox(height: 20),
            RoomStartButton(
              key: const Key('rooms-empty-create'),
              label: context.getString.rooms_create,
              icon: Icons.add_rounded,
              breathe: false,
              onTap: onCreate,
            ),
          ],
        ),
      ),
    ),
  );
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
