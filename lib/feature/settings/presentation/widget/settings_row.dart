import 'package:flutter/material.dart';

import '../../../../core/motion/app_motion.dart';
import '../../../../core/theme/app_colors.dart';

/// Leading-icon + label(+subtitle) + trailing-control row — the one list-row
/// primitive the whole Settings page uses, so every section reads as one
/// coherent surface instead of several ad hoc layouts.
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Tints the icon and label, for an action that cannot be taken back
  /// (deleting an account). Amber when null.
  final Color? tint;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    required this.trailing,
    this.subtitle,
    this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tint ?? AppColors.amber;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withAlpha(22),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: accent, size: 17),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: tint ?? AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
    if (onTap == null) return row;
    // A small settle under the finger, so a tappable row answers the touch.
    return PressableScale(onTap: onTap, scale: 0.98, child: row);
  }
}
