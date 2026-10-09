import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/monogram_mark.dart';
import '../../../../core/widget/sheet_shell.dart';

enum RoomAction { rename, archive, leave, delete }

/// Room management uses the same floating panel as the archive and confirmations.
/// Wait for the panel to leave before opening the chosen action's next surface.
Future<RoomAction?> showRoomActionsSheet(
  BuildContext context, {
  required String roomName,
  bool archived = false,
}) async {
  final transition =
      BottomSheet.createAnimationController(Navigator.of(context))
        ..duration = AppMotion.reduced(context)
            ? Duration.zero
            : AppMotion.sheet
        ..reverseDuration = AppMotion.reduced(context)
            ? Duration.zero
            : AppMotion.sheet;
  final dismissed = Completer<void>();
  transition.addStatusListener((status) {
    if (status == AnimationStatus.dismissed && !dismissed.isCompleted) {
      dismissed.complete();
    }
  });
  try {
    final action = await showModalBottomSheet<RoomAction>(
      context: context,
      routeSettings: const RouteSettings(name: 'RoomMenu'),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      transitionAnimationController: transition,
      builder: (_) => _RoomActions(roomName: roomName, archived: archived),
    );
    if (transition.status != AnimationStatus.dismissed) {
      await dismissed.future;
    }
    return action;
  } finally {
    transition.dispose();
  }
}

class _RoomActions extends StatelessWidget {
  const _RoomActions({required this.roomName, required this.archived});

  final String roomName;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final strings = context.getString;
    return SheetShell(
      key: const Key('room-actions-sheet'),
      topFraction: 0.16,
      surfaceColor: AppColors.fieldSurface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6, bottom: 16),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: MonogramMark(
                      name: roomName,
                      accent: AppColors.amber,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.rooms_manage,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          roomName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('room-actions-close'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            _ActionRow(
              action: RoomAction.rename,
              label: strings.rooms_rename,
              icon: Icons.edit_outlined,
            ),
            if (!archived)
              _ActionRow(
                action: RoomAction.archive,
                label: strings.rooms_archive,
                icon: Icons.inventory_2_outlined,
              ),
            _ActionRow(
              action: RoomAction.leave,
              label: strings.rooms_leave,
              icon: Icons.logout_rounded,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Divider(height: 1, color: AppColors.border),
            ),
            _ActionRow(
              action: RoomAction.delete,
              label: strings.rooms_delete,
              icon: Icons.delete_outline_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.label,
    required this.icon,
  });

  final RoomAction action;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final destructive = action == RoomAction.delete;
    final color = destructive ? AppColors.red : AppColors.textPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('room-action-${action.name}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          HapticFeedback.selectionClick();
          Navigator.of(context).pop(action);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 21,
                  color: destructive ? color : AppColors.textSecondary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
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
