import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';

/// Names the part a member plays in the link, in radio terms rather than
/// networking ones — the person reading it wants to know who is holding the
/// channel up, not which end opened the socket.
///
/// Renders nothing for [SessionRole.unknown]: a peer on an older build never
/// announces a role, and inventing one for them would be a guess.
class RoleBadge extends StatelessWidget {
  final SessionRole role;

  /// Type size; the glyph tracks it. Defaults to the member-tile size.
  final double fontSize;

  const RoleBadge({super.key, required this.role, this.fontSize = 11});

  @override
  Widget build(BuildContext context) {
    if (role == SessionRole.unknown) return const SizedBox.shrink();
    final s = context.getString;
    final (icon, label) = switch (role) {
      SessionRole.host => (Icons.cell_tower_rounded, s.role_host),
      SessionRole.joiner => (
        Icons.settings_input_antenna_rounded,
        s.role_joiner,
      ),
      SessionRole.peer => (Icons.podcasts_rounded, s.role_peer),
      SessionRole.unknown => (Icons.circle, ''),
    };
    // The host is the one whose leaving ends the session for everyone, so it
    // gets the accent; the rest stay quiet under the name.
    final color = role == SessionRole.host
        ? AppColors.amber
        : AppColors.textSecondary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: fontSize + 1, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
