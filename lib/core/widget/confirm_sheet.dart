import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/extension.dart';
import '../motion/app_motion.dart';
import '../theme/app_colors.dart';
import 'sheet_shell.dart';

/// Asks before something the user cannot casually undo.
///
/// Replaces the stock `AlertDialog` these actions used to raise. A dialog put
/// the two outcomes side by side as identical text buttons, which is exactly
/// backwards for a destructive choice: the safe option should be the easy one
/// to hit and the dangerous one should cost a deliberate reach. Here cancel is
/// full-width underneath, and the destructive action carries its own colour and
/// icon rather than being distinguished by wording alone.
///
/// Returns false on a dismissal — tapping the scrim, the back gesture, anything
/// that is not the action button itself.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  required IconData icon,
  bool destructive = false,
  String? cancelLabel,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      builder: (_) => _ConfirmSheet(
        title: title,
        body: body,
        action: action,
        icon: icon,
        destructive: destructive,
        cancelLabel: cancelLabel,
      ),
    ) ??
    false;

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.body,
    required this.action,
    required this.icon,
    required this.destructive,
    required this.cancelLabel,
  });

  final String title;
  final String body;
  final String action;
  final IconData icon;
  final bool destructive;
  final String? cancelLabel;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? AppColors.red : AppColors.amber;
    return SheetShell(
      // Shorter than a browsing sheet: this one is a question, and letting it
      // stand tall would imply there is more to read than there is.
      topFraction: 0.4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
        child: StaggeredEntrance(
          builder: (context, children) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: accent.withValues(alpha: 0.45)),
                  ),
                  child: Icon(icon, size: 21, color: accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              body,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13.5,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 20),
            _ActionButton(
              key: const Key('confirm-sheet-action'),
              label: action,
              icon: icon,
              accent: accent,
              onTap: () {
                if (destructive) HapticFeedback.mediumImpact();
                Navigator.pop(context, true);
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('confirm-sheet-cancel'),
              onPressed: () => Navigator.pop(context, false),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                cancelLabel ?? context.getString.confirm_cancel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.accent,
    required this.onTap,
    super.key,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: PressableScale(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: accent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: accent,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
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
