import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/qr_widgets.dart';
import 'hotspot_shared_widgets.dart';

/// The plain Wi-Fi segment: both devices already share a network — nothing
/// to set up, just enter the channel.
class WifiOnlyFlow extends StatelessWidget {
  final VoidCallback onEnterChannel;

  const WifiOnlyFlow({super.key, required this.onEnterChannel});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      children: [
        HotspotEntrance(
          delayMs: 0,
          child: Center(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amber.withAlpha(20),
                border: Border.all(color: AppColors.amber.withAlpha(120)),
              ),
              child: Icon(Icons.wifi_rounded, color: AppColors.amber, size: 38),
            ),
          ),
        ),
        const SizedBox(height: 20),
        HotspotEntrance(
          delayMs: 80,
          child: Text(
            s.wifi_only_instructions,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 24),
        HotspotEntrance(
          delayMs: 140,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                StepRow(
                  index: 1,
                  icon: Icons.wifi_rounded,
                  text: s.wifi_only_step_same_network,
                ),
                const SizedBox(height: 12),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 12),
                StepRow(
                  index: 2,
                  icon: Icons.podcasts_rounded,
                  text: s.hotspot_step_join_channel,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        HotspotEntrance(
          delayMs: 200,
          child: HotspotPrimaryButton(
            icon: Icons.arrow_forward_rounded,
            label: s.hotspot_enter_channel,
            onTap: onEnterChannel,
          ),
        ),
      ],
    );
  }
}
