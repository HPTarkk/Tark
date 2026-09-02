import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/monogram_mark.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';
import '../widget/room_archive_sheet.dart';

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
    final copy = _RoomCopy.of(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        title: Text(copy.title),
        actions: [
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
                      label: copy.archivedRooms,
                      countLabel: copy.archivedCount(state.archived.length),
                      onTap: () => showRoomArchiveSheet(context),
                    ),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      // Creation now lives here as well as on Landing. Keeping it only on
      // Landing meant the one screen listing your Rooms was the one screen
      // that could not make another — so adding a second Room meant backing
      // out to the home screen to find the button.
      floatingActionButton: BlocBuilder<RoomListCubit, RoomListState>(
        buildWhen: (p, c) => p.rooms.isEmpty != c.rooms.isEmpty,
        builder: (context, state) => state.rooms.isEmpty
            // The empty state already offers creation as its subject; a second
            // floating copy of it would be the only two controls on screen
            // both saying the same thing.
            ? const SizedBox.shrink()
            : FloatingActionButton.extended(
                key: const Key('rooms-create-fab'),
                onPressed: () => _createRoom(context),
                backgroundColor: AppColors.amber,
                foregroundColor: AppColors.background,
                icon: const Icon(Icons.add_rounded),
                label: Text(
                  copy.newRoom,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
      ),
      body: SafeArea(
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
              switchOutCurve: AppMotion.easeOut,
              // The outgoing state is not laid out under the incoming one —
              // otherwise an empty state and a full list fight over the height
              // for the length of the fade.
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [
                  ...previous.map(
                    (child) =>
                        Positioned.fill(child: IgnorePointer(child: child)),
                  ),
                  ?current,
                ],
              ),
              child: _body(context, state, copy),
            );
          },
        ),
      ),
    );
  }

  Widget _body(BuildContext context, RoomListState state, _RoomCopy copy) {
    if (state.loading && state.rooms.isEmpty) {
      return const Center(
        key: ValueKey('rooms-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.error != null && state.rooms.isEmpty) {
      return _ErrorState(
        key: const ValueKey('rooms-error'),
        copy: copy,
        onRetry: context.read<RoomListCubit>().load,
      );
    }
    if (state.rooms.isEmpty) {
      return _EmptyState(
        key: const ValueKey('rooms-empty'),
        copy: copy,
        onCreate: () => _createRoom(context),
      );
    }
    return RefreshIndicator(
      key: const ValueKey('rooms-list-view'),
      onRefresh: context.read<RoomListCubit>().load,
      child: StaggeredEntrance(
        children: [
          for (final saved in state.rooms)
            _RoomCard(
              saved: saved,
              selected: state.selectedRoomId == saved.room.id,
              busy: state.loading,
              copy: copy,
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
        ],
        builder: (context, children) => ListView.separated(
          key: const Key('rooms-list'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (context, index) => children[index],
        ),
      ),
    );
  }

  Future<void> _createRoom(BuildContext context) async {
    final copy = _RoomCopy.of(context);
    final name = await _nameDialog(
      context,
      title: copy.create,
      action: copy.create,
      hint: copy.roomNameHint,
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
          ? copy.fallbackMemberName
          : localDisplayName.trim(),
    );
    if (created != null && context.mounted) {
      context.go(AppRoutes.walkiePath);
    }
  }

  Future<void> _renameRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final name = await _nameDialog(
      context,
      title: copy.rename,
      action: copy.save,
      hint: copy.roomNameHint,
      initialValue: saved.room.name,
    );
    if (name == null || !context.mounted) return;
    await context.read<RoomListCubit>().rename(saved.room.id, name);
  }

  Future<void> _archiveRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final confirmed = await showConfirmSheet(
      context,
      title: copy.archive,
      body: copy.archiveConfirm(saved.room.name),
      action: copy.archive,
      icon: Icons.inventory_2_outlined,
    );
    if (confirmed && context.mounted) {
      await context.read<RoomListCubit>().archive(saved.room.id);
    }
  }

  Future<void> _leaveRoom(BuildContext context, SavedRoom saved) async {
    final copy = _RoomCopy.of(context);
    final confirmed = await showConfirmSheet(
      context,
      title: copy.leave,
      body: copy.leaveConfirm(saved.room.name),
      action: copy.leave,
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
    final copy = _RoomCopy.of(context);
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
            child: Text(copy.cancel),
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

/// One saved Room.
///
/// The old card put the room's name on one line, a member count and an
/// overflow menu on the next, and then *either* a Start button or a "Select
/// this room" text button — so the primary action moved vertically depending
/// on state, and an unselected card's only call to action restated what
/// tapping the card already did.
///
/// Now there is one hierarchy that never moves: a mark, the name, one line of
/// metadata, and the menu. Selection adds the Start action underneath rather
/// than replacing anything, so nothing the user was already looking at jumps.
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.saved,
    required this.selected,
    required this.busy,
    required this.copy,
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
  final _RoomCopy copy;
  final VoidCallback onSelect;
  final VoidCallback? onStart;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  static final _radius = BorderRadius.circular(20);

  @override
  Widget build(BuildContext context) {
    // Confirmed, not active: an unused invite holds a durable seat and must
    // not be counted as a person who is in the room.
    final members = saved.room.confirmedMembers.length;
    final pending = saved.room.pendingMembers.length;
    final archived = saved.room.archived;
    final accent = archived
        ? AppColors.textSecondary
        : selected
        ? AppColors.amber
        : AppColors.textSecondary;

    return Semantics(
      selected: selected,
      button: !archived,
      label: copy.roomSemantics(saved.room.name, members, selected),
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
          // Border colour, border width and the glow all travel together on one
          // curve. Snapping between a 1px grey outline and a 2px amber one is
          // the difference between a list that responds and a list that
          // redraws.
          duration: AppMotion.card,
          curve: AppMotion.easeOut,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: _radius,
            border: Border.all(
              color: selected ? AppColors.amber : AppColors.border,
              width: selected ? 2 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.amber.withValues(alpha: 0.16),
                      blurRadius: 26,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: _radius,
            child: Stack(
              children: [
                // A soft wash from the leading edge, so a selected card reads
                // as lit from the side rather than merely outlined. Painted
                // under the content and clipped by the card, which costs one
                // gradient and no extra layer.
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      duration: AppMotion.card,
                      curve: AppMotion.easeOut,
                      opacity: selected ? 1 : 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: AlignmentDirectional.centerStart,
                            end: AlignmentDirectional.centerEnd,
                            colors: [
                              AppColors.amber.withValues(alpha: 0.10),
                              AppColors.amber.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _RoomMark(
                            name: saved.room.name,
                            selected: selected,
                            archived: archived,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
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
                                    ),
                                    if (selected && !archived) ...[
                                      const SizedBox(width: 8),
                                      _Dot(color: AppColors.amber),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 5),
                                _MetaLine(
                                  members: members,
                                  pending: pending,
                                  archived: archived,
                                  canInvite: saved.membership.canManageInvites,
                                  accent: accent,
                                  copy: copy,
                                ),
                              ],
                            ),
                          ),
                          _RoomMenu(
                            saved: saved,
                            busy: busy,
                            archived: archived,
                            copy: copy,
                            onRename: onRename,
                            onArchive: onArchive,
                            onLeave: onLeave,
                            onDelete: onDelete,
                          ),
                        ],
                      ),
                      // Grows in under the identity rather than swapping with
                      // it, so selecting a card never reflows the line the
                      // user just read.
                      AnimatedSize(
                        duration: AppMotion.card,
                        curve: AppMotion.easeOut,
                        alignment: Alignment.topCenter,
                        child: selected && !archived
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(0, 14, 6, 0),
                                child: _StartRow(
                                  key: Key('room-start-${saved.room.id.value}'),
                                  label: copy.startRide,
                                  busy: busy,
                                  onTap: onStart,
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
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

/// The room's monogram, which is the fastest thing on the card to recognise
/// at a glance in a list of five.
class _RoomMark extends StatelessWidget {
  const _RoomMark({
    required this.name,
    required this.selected,
    required this.archived,
  });

  final String name;
  final bool selected;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final accent = archived
        ? AppColors.textSecondary
        : selected
        ? AppColors.amber
        : AppColors.textSecondary;
    // Shared with Landing's resume action, so the card you pick a room from and
    // the button that resumes it are the same object rather than two drawings
    // of one.
    return MonogramMark(
      name: name,
      accent: accent,
      strong: selected,
      child: archived
          ? Icon(Icons.archive_rounded, size: 19, color: accent)
          : null,
    );
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
    required this.copy,
  });

  final int members;
  final int pending;
  final bool archived;
  final bool canInvite;
  final Color accent;
  final _RoomCopy copy;

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
            copy.memberCount(members),
            accent,
          ),
          if (pending > 0)
            _item(
              constraints.maxWidth,
              Icons.hourglass_top_rounded,
              copy.pendingSeats(pending),
              AppColors.textSecondary,
            ),
          if (archived)
            Text(
              copy.archived,
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
              copy.canInvite,
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

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 7),
      ],
    ),
  );
}

class _StartRow extends StatelessWidget {
  const _StartRow({
    required this.label,
    required this.busy,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PressableScale(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(13),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: AppColors.amber, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_arrow_rounded, color: AppColors.amber, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RoomMenu extends StatelessWidget {
  const _RoomMenu({
    required this.saved,
    required this.busy,
    required this.archived,
    required this.copy,
    required this.onRename,
    required this.onArchive,
    required this.onLeave,
    required this.onDelete,
  });

  final SavedRoom saved;
  final bool busy;
  final bool archived;
  final _RoomCopy copy;
  final VoidCallback onRename;
  final VoidCallback onArchive;
  final VoidCallback onLeave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_RoomAction>(
    key: Key('room-menu-${saved.room.id.value}'),
    enabled: !busy,
    tooltip: copy.manage,
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
      PopupMenuItem(value: _RoomAction.rename, child: Text(copy.rename)),
      if (!archived)
        PopupMenuItem(value: _RoomAction.archive, child: Text(copy.archive)),
      PopupMenuItem(value: _RoomAction.leave, child: Text(copy.leave)),
      // Last, and the only coloured item: archive and leave are both
      // recoverable, and this one is not.
      PopupMenuItem(
        value: _RoomAction.delete,
        child: Text(
          copy.delete,
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
  const _EmptyState({required this.copy, required this.onCreate, super.key});

  final _RoomCopy copy;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_2_outlined, size: 56, color: AppColors.amber),
            const SizedBox(height: 18),
            Text(
              copy.emptyTitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              copy.emptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(copy.create),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.copy, required this.onRetry, super.key});

  final _RoomCopy copy;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 48, color: AppColors.amber),
          const SizedBox(height: 12),
          Text(copy.loadError, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(copy.retry),
          ),
        ],
      ),
    ),
  );
}

/// Small bilingual copy surface kept local to this new page until the next
/// generated-l10n sweep. It provides complete fa/en parity immediately and
/// follows the app's ambient Directionality, including RTL Persian layouts.
final class _RoomCopy {
  const _RoomCopy({required this.fa});

  factory _RoomCopy.of(BuildContext context) => _RoomCopy(
    fa: Localizations.localeOf(context).languageCode.toLowerCase() == 'fa',
  );

  final bool fa;

  String get title => fa ? 'اتاق‌های ذخیره‌شده' : 'Saved rooms';
  String get create => fa ? 'ساخت اتاق' : 'Create room';
  String get rename => fa ? 'تغییر نام' : 'Rename';
  String get save => fa ? 'ذخیره' : 'Save';
  String get archive => fa ? 'بایگانی' : 'Archive';
  String get archived => fa ? 'بایگانی‌شده' : 'Archived';
  String get leave => fa ? 'ترک اتاق' : 'Leave room';
  String get cancel => fa ? 'انصراف' : 'Cancel';
  String get select => fa ? 'انتخاب این اتاق' : 'Select this room';
  String get selected => fa ? 'انتخاب‌شده' : 'Selected';
  String get startRide => fa ? 'شروع ارتباط' : 'Start ride';
  String get manage => fa ? 'مدیریت اتاق' : 'Manage room';
  String get retry => fa ? 'تلاش دوباره' : 'Retry';
  String get roomNameHint => fa ? 'نام اتاق' : 'Room name';
  String get fallbackMemberName => fa ? 'راننده' : 'Rider';
  String get emptyTitle => fa ? 'هنوز اتاقی ندارید' : 'No saved rooms yet';
  String get emptyBody => fa
      ? 'اتاق‌ها بدون اینترنت هم روی همین گوشی باقی می‌مانند. ساخت یا انتخاب اتاق به‌تنهایی هات‌اسپات یا میکروفن را روشن نمی‌کند.'
      : 'Rooms stay on this phone offline. Creating or selecting one never starts a hotspot or microphone by itself.';
  String get loadError => fa
      ? 'اتاق‌های ذخیره‌شده خوانده نشدند. چیزی حذف نشده است.'
      : 'Saved rooms could not be loaded. Nothing was deleted.';

  String get canInvite => fa ? 'می‌توانید دعوت کنید' : 'You can invite';
  String get delete => fa ? 'حذف اتاق' : 'Delete room';
  String get archivedRooms => fa ? 'اتاق‌های بایگانی‌شده' : 'Archived rooms';
  String get newRoom => fa ? 'اتاق تازه' : 'New room';

  /// Digits the user reads as a quantity, in their own numerals.
  ///
  /// Only quantities. Identifiers — a Room code, an invite check value, a Wi-Fi
  /// passphrase — deliberately stay in Latin digits: two phones in different
  /// locales have to render those identically to be compared or typed, and a
  /// Persian ۵ cannot be entered into Android's Wi-Fi dialog.
  String _n(int value) => localizeDigits('$value', farsi: fa);

  String memberCount(int count) =>
      fa ? '${_n(count)} عضو' : '${_n(count)} members';
  String pendingSeats(int count) => fa
      ? '${_n(count)} جای بازشده'
      : '${_n(count)} open seat${count == 1 ? '' : 's'}';
  String archivedCount(int count) => _n(count);
  String archiveConfirm(String name) => fa
      ? '«$name» از فهرست کنار می‌رود و عضویتش دست‌نخورده می‌ماند. هر وقت خواستید از بایگانی برش گردانید.'
      : 'Moves “$name” out of the list with its membership intact. Bring it back from the archive whenever you want.';
  String leaveConfirm(String name) => fa
      ? 'عضویت شما در «$name» حذف شود؟ این کار با پایان دادن یک جلسه زنده فرق دارد.'
      : 'Leave “$name”? This removes your membership and is different from ending a live session.';
  String roomSemantics(String name, int count, bool selected) => fa
      ? '$name، ${_n(count)} عضو${selected ? '، انتخاب‌شده' : ''}'
      : '$name, ${_n(count)} members${selected ? ', selected' : ''}';
}
