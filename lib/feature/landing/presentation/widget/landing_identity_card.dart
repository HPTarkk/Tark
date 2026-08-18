import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';

/// Identity card on the landing page: avatar, name, IP and edit button.
class LandingIdentityCard extends StatelessWidget {
  final LandingState state;
  final VoidCallback onEdit;

  const LandingIdentityCard({
    super.key,
    required this.state,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    // An IP address told the user nothing they could act on. What they
    // actually want to know from this line is whether they can talk yet —
    // and over what, which the icon says rather than a second label.
    //
    // Read off the plan rather than off `state.transferMode`, which is the
    // *last* transport used and, under automatic, says nothing about the one
    // the buttons below are about to take. Bluetooth and a hotspot need no
    // existing Wi-Fi, so a phone with no network still reads READY when the
    // advisor has a route for it — only a plan with nowhere to go says
    // otherwise, which is [ChannelPlan.blocked].
    final plan = state.planFor(ChannelIntent.create);
    final ready = !plan.blocked;
    final networkStatus = state.isLoading
        ? s.connecting
        : (ready ? s.landing_ready : s.no_network);
    final transportIcon = switch (plan.mode) {
      TransferMode.bluetooth => Icons.bluetooth_rounded,
      TransferMode.hotspot => Icons.wifi_tethering_rounded,
      TransferMode.guest => Icons.public_rounded,
      TransferMode.wifi => Icons.wifi_rounded,
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: Row(
        children: [
          AppAvatar(name: state.myName, size: 50),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.myName.isEmpty ? '...' : state.myName,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Icon(
                        ready ? transportIcon : Icons.wifi_off_rounded,
                        key: ValueKey(ready ? state.transferMode : null),
                        color: ready ? AppColors.textSecondary : AppColors.red,
                        size: 13,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TickerText(
                        text: networkStatus,
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          color: ready ? AppColors.textSecondary : AppColors.red,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onEdit,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_rounded, color: AppColors.amber, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    s.edit_name,
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 10,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
