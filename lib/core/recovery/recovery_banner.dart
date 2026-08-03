import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'recovery_action.dart';
import 'recovery_check.dart';

/// The one way this app tells someone that something is wrong and what to do
/// about it.
///
/// Every failure surface used to be bespoke — an error card here, a snackbar
/// there, and in the worst cases nothing at all. This is deliberately the
/// single shape: a tinted rounded card, a plain-language line, and the fixes
/// as tappable chips underneath. Severity only changes the colour and the
/// glyph, never the layout, so a red one and an amber one are read the same
/// way rather than needing to be learned separately.
///
/// Renders nothing (and takes no space) when [issue] is null, so callers can
/// leave it in the tree unconditionally and let it animate itself open.
class RecoveryBanner extends StatelessWidget {
  const RecoveryBanner({
    super.key,
    required this.issue,
    this.compact = false,
  });

  /// The problem to show, or null for "everything's fine".
  final RecoveryCheck? issue;

  /// Tighter padding for use inside an already-padded card.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = issue;
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: current == null || current.isHealthy
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _card(current),
            ),
    );
  }

  Widget _card(RecoveryCheck check) {
    final accent = accentFor(check.status);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        color: accent.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(iconFor(check.status), color: accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      check.label,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (check.detail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        check.detail,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ],
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

  static Color accentFor(RecoveryStatus status) => switch (status) {
    RecoveryStatus.bad => AppColors.red,
    RecoveryStatus.warn => AppColors.amber,
    RecoveryStatus.ok => AppColors.green,
    RecoveryStatus.unknown => AppColors.textSecondary,
  };

  static IconData iconFor(RecoveryStatus status) => switch (status) {
    RecoveryStatus.bad => Icons.error_outline_rounded,
    RecoveryStatus.warn => Icons.info_outline_rounded,
    RecoveryStatus.ok => Icons.check_circle_rounded,
    RecoveryStatus.unknown => Icons.help_outline_rounded,
  };
}

/// The fix chips. Wraps rather than scrolls, so a long label on a narrow
/// phone drops to its own line instead of being clipped — these are the
/// user's way out, and a way out you can't read is no way out.
class RecoveryActionRow extends StatelessWidget {
  const RecoveryActionRow({
    super.key,
    required this.actions,
    required this.accent,
  });

  final List<RecoveryAction> actions;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final action in actions)
          _ActionChip(action: action, accent: accent),
      ],
    );
  }
}

class _ActionChip extends StatefulWidget {
  const _ActionChip({required this.action, required this.accent});

  final RecoveryAction action;
  final Color accent;

  @override
  State<_ActionChip> createState() => _ActionChipState();
}

class _ActionChipState extends State<_ActionChip> {
  /// A fix can take a moment (a permission round-trip, a reconnect). Showing
  /// it running is what stops the user tapping four times and queueing four
  /// of them.
  bool _running = false;
  bool _pressed = false;

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await widget.action.run();
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.action.isPrimary;
    final accent = widget.accent;
    return GestureDetector(
      onTap: _run,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: filled ? accent.withAlpha(30) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withAlpha(filled ? 140 : 90)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_running) ...[
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                widget.action.label,
                style: TextStyle(
                  color: accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
