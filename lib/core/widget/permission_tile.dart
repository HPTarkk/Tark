import 'package:flutter/material.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';

/// Status of a single OS permission or device capability the app needs.
enum PermissionTileStatus { granted, denied, permanentlyDenied }

/// One row in a permissions overview: icon, plain-language reason, current
/// status, and the one action that makes sense for that status (request, or
/// open OS settings when the OS refuses to prompt again).
///
/// Shared across the dedicated Permissions page, the Bluetooth connect page,
/// and the WiFi/Hotspot page — a genuinely cross-feature widget, hence
/// core/widget rather than living inside any one feature.
class PermissionTile extends StatelessWidget {
  const PermissionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.status,
    required this.onRequest,
    this.onOpenSettings,
  });

  final IconData icon;
  final String title;
  final String description;
  final PermissionTileStatus status;
  final Future<void> Function() onRequest;
  final Future<void> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isGranted = status == PermissionTileStatus.granted;
    final accent = isGranted ? AppColors.green : AppColors.amber;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withAlpha(70)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withAlpha(25),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 10),
                if (isGranted)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        color: AppColors.green,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        s.permission_granted,
                        style: TextStyle(
                          color: AppColors.green,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                else
                  GestureDetector(
                    onTap: () =>
                        status == PermissionTileStatus.permanentlyDenied
                        ? onOpenSettings?.call()
                        : onRequest(),
                    child: Text(
                      status == PermissionTileStatus.permanentlyDenied
                          ? s.open_settings
                          : s.permission_grant,
                      style: TextStyle(
                        color: AppColors.amber,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
