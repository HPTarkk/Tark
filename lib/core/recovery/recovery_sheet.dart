import 'package:flutter/material.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';
import 'recovery_banner.dart';
import 'recovery_check.dart';

/// The always-available "something's not working" sheet.
///
/// Its whole job is to guarantee there is never a dead end. Banners cover the
/// failures we predicted; this covers the ones we didn't, by showing the live
/// state of each thing the session depends on and putting the fix next to
/// whatever is red. Even when every row is green it still answers a real
/// question — "is it me?" — which is the state people otherwise sit in.
///
/// Fed by a stream so the rows correct themselves while the sheet is open:
/// the user grants the mic permission from the row's own button, comes back,
/// and watches it turn green without having to close and reopen anything.
Future<void> showRecoverySheet(
  BuildContext context, {
  required List<RecoveryCheck> initial,
  required Stream<List<RecoveryCheck>> checks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _RecoverySheet(initial: initial, checks: checks),
  );
}

class _RecoverySheet extends StatelessWidget {
  const _RecoverySheet({required this.initial, required this.checks});

  final List<RecoveryCheck> initial;
  final Stream<List<RecoveryCheck>> checks;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: SafeArea(
        top: false,
        child: StreamBuilder<List<RecoveryCheck>>(
          stream: checks,
          initialData: initial,
          builder: (context, snapshot) {
            final rows = snapshot.data ?? initial;
            final broken = rows.where((c) => !c.isHealthy).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 18),
                // Full width, not shrink-wrapped. The enclosing column centres
                // its children (which is what keeps the drag handle centred),
                // so without this the header block centres too — and a centred
                // header over left-aligned rows reads as two different lists.
                SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.help_title,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          broken.isEmpty
                              ? s.help_all_good
                              : s.help_found_problems,
                          style: TextStyle(
                            color: broken.isEmpty
                                ? AppColors.green
                                : AppColors.textSecondary,
                            fontSize: 12.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _CheckRow(check: rows[i]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One checked thing. Healthy rows stay visually quiet — flat, no tint — so
/// the eye lands straight on whatever is actually wrong.
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final RecoveryCheck check;

  @override
  Widget build(BuildContext context) {
    final accent = RecoveryBanner.accentFor(check.status);
    final healthy = check.isHealthy;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: healthy ? Colors.transparent : accent.withAlpha(16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: healthy ? AppColors.border : accent.withAlpha(110),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cross-fades on status change so a row going green while the
              // sheet is open reads as a result, not a repaint.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Icon(
                  RecoveryBanner.iconFor(check.status),
                  key: ValueKey(check.status),
                  color: accent,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      check.label,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      check.detail,
                      style: TextStyle(
                        color: healthy ? AppColors.textSecondary : accent,
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (check.actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            RecoveryActionRow(actions: check.actions, accent: accent),
          ],
        ],
      ),
    );
  }
}
