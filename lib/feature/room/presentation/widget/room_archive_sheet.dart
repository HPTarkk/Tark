import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/confirm_sheet.dart';
import '../../../../core/widget/sheet_shell.dart';
import '../../domain/entity/room.dart';
import '../manager/room_list_cubit.dart';

/// Where put-away Rooms live, and the only way back out of the archive.
///
/// Archive used to be a one-way door: `setArchived` hid the Room and nothing
/// in the app ever passed `includeArchived: true`, so a put-away Room was
/// invisible forever, still on disk, and impossible to restore. This sheet is
/// the other half of that verb — and the reason delete can now be a separate,
/// honest action instead of archive quietly doing duty as one.
Future<void> showRoomArchiveSheet(BuildContext context) {
  final cubit = context.read<RoomListCubit>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    // The sheet drives the same cubit as the page underneath, so restoring a
    // Room updates the list behind it rather than leaving two truths on
    // screen at once.
    builder: (_) =>
        BlocProvider<RoomListCubit>.value(value: cubit, child: const _Sheet()),
  );
}

class _Sheet extends StatelessWidget {
  const _Sheet();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RoomListCubit, RoomListState>(
      // Emptying the archive closes it. Leaving an empty panel open would make
      // the user dismiss a sheet whose whole subject they just cleared.
      listenWhen: (previous, current) =>
          previous.archived.isNotEmpty && current.archived.isEmpty,
      listener: (context, _) => Navigator.of(context).maybePop(),
      builder: (context, state) => SheetShell(
        topFraction: 0.14,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SheetTitle(
                title: context.getString.archive_eyebrow,
                subtitle: context.getString.archive_title,
                // Cool, not amber: the archive is the one Room surface that is
                // deliberately not the live path.
                accent: AppColors.textSecondary,
              ),
              const SizedBox(height: 6),
              Text(
                context.getString.archive_blurb,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              // Restores and deletes take rows out from under the user, so the
              // list closes the gap rather than snapping shut.
              AnimatedSize(
                duration: AppMotion.card,
                curve: AppMotion.easeOut,
                alignment: Alignment.topCenter,
                child: StaggeredEntrance(
                  builder: (context, children) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                  children: [
                    for (final saved in state.archived) ...[
                      _ArchivedRoomCard(
                        key: Key('archived-${saved.room.id.value}'),
                        saved: saved,
                        busy: state.loading,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One put-away Room.
///
/// Reads as cold storage rather than a dimmed copy of the live card: a grey
/// rail down the leading edge, no amber anywhere except the control that
/// brings it back. The colour returning *is* the affordance.
class _ArchivedRoomCard extends StatelessWidget {
  const _ArchivedRoomCard({required this.saved, required this.busy, super.key});

  final SavedRoom saved;
  final bool busy;

  static final _radius = BorderRadius.circular(16);

  @override
  Widget build(BuildContext context) {
    final members = saved.room.confirmedMembers.length;
    return Semantics(
      label: context.getString.archive_card_semantics(
        saved.room.name,
        members.localized(context),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: _radius,
          border: Border.all(color: AppColors.border),
        ),
        child: ClipRRect(
          borderRadius: _radius,
          child: Row(
            children: [
              // The rail is what separates a put-away room from a live card
              // at a glance. It has to be cool and it has to be *visible* —
              // drawn in the border colour it was invisible against the card,
              // which is a decoration that costs layout and pays nothing.
              Container(
                width: 4,
                height: 92,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.textSecondary.withValues(alpha: 0.75),
                      AppColors.textSecondary.withValues(alpha: 0.25),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 17,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              saved.room.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            context.getString.archive_member_count(
                              members.localized(context),
                            ),
                            style: TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _RowAction(
                              key: Key('restore-${saved.room.id.value}'),
                              label: context.getString.archive_restore,
                              icon: Icons.unarchive_rounded,
                              accent: AppColors.amber,
                              onTap: busy
                                  ? null
                                  : () => _restore(context, saved),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _RowAction(
                            key: Key('delete-${saved.room.id.value}'),
                            label: context.getString.archive_delete,
                            icon: Icons.delete_outline_rounded,
                            accent: AppColors.red,
                            compact: true,
                            onTap: busy
                                ? null
                                : () => confirmAndDeleteRoom(context, saved),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _restore(BuildContext context, SavedRoom saved) async {
    HapticFeedback.selectionClick();
    await context.read<RoomListCubit>().unarchive(saved.room.id);
  }
}

/// Asks, then deletes — shared with the saved-Rooms list so the question is
/// worded identically wherever the Room is deleted from.
Future<void> confirmAndDeleteRoom(BuildContext context, SavedRoom saved) async {
  final confirmed = await showConfirmSheet(
    context,
    title: context.getString.archive_delete_title,
    body: context.getString.archive_delete_confirm(saved.room.name),
    action: context.getString.archive_delete_action,
    icon: Icons.delete_outline_rounded,
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;
  await context.read<RoomListCubit>().deleteRoom(saved.room.id);
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
    this.compact = false,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;

  /// Icon only, with the label carried by Semantics — for the action that
  /// should be reachable but never the one the eye lands on first.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final tint = enabled ? accent : AppColors.textSecondary;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: PressableScale(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint.withValues(alpha: enabled ? 0.12 : 0.05),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: tint.withValues(alpha: 0.55)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: 10,
              horizontal: compact ? 12 : 10,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: tint),
                if (!compact) ...[
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tint,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
