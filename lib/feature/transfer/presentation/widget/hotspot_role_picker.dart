import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/wifi_hotspot_cubit.dart';
import 'hotspot_shared_widgets.dart';

/// The first thing the Hotspot segment asks on Android: which end of the
/// bridge is this phone?
///
/// It exists for two reasons. Android used to be hard-wired as the host, so two
/// Android phones had no in-app way to pair — the second one had to leave for
/// the camera and Wi-Fi settings. And starting a hotspot the moment the segment
/// opened meant a phone that can't host (tethering already on, Location off)
/// greeted the user with a failure they never asked for.
class HotspotRolePicker extends StatelessWidget {
  final ValueChanged<HotspotRole> onChoose;

  const HotspotRolePicker({super.key, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Text(
            s.hotspot_role_title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 8),
        HotspotEntrance(
          delayMs: 60,
          child: Text(
            s.hotspot_role_hint,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        HotspotEntrance(
          delayMs: 120,
          child: _RoleCard(
            icon: Icons.wifi_tethering_rounded,
            title: s.hotspot_role_host,
            description: s.hotspot_role_host_desc,
            onTap: () => onChoose(HotspotRole.host),
          ),
        ),
        const SizedBox(height: 14),
        HotspotEntrance(
          delayMs: 180,
          child: _RoleCard(
            icon: Icons.qr_code_scanner_rounded,
            title: s.hotspot_role_join,
            description: s.hotspot_role_join_desc,
            onTap: () => onChoose(HotspotRole.join),
          ),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.amber.withAlpha(90)),
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amber.withAlpha(22),
                border: Border.all(color: AppColors.amber.withAlpha(110)),
              ),
              child: Icon(icon, color: AppColors.amber, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.3,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    description,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}
