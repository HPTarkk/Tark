import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/ticker_text.dart';
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
    final hasNetwork = state.hasNetwork;
    final displayIp = state.isLoading
        ? s.connecting
        : (hasNetwork ? state.localIp.localized(context) : s.no_network);

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
                  style: const TextStyle(
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
                        hasNetwork
                            ? Icons.router_rounded
                            : Icons.wifi_off_rounded,
                        key: ValueKey(hasNetwork),
                        color: hasNetwork
                            ? AppColors.textSecondary
                            : AppColors.red,
                        size: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TickerText(
                        text: displayIp,
                        duration: const Duration(milliseconds: 300),
                        style: TextStyle(
                          color: hasNetwork
                              ? AppColors.textSecondary
                              : AppColors.red,
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
                  const Icon(Icons.edit_rounded, color: AppColors.amber, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    s.edit_name,
                    style: const TextStyle(
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
