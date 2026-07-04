import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/landing_cubit.dart';

/// WiFi / Bluetooth segmented toggle for choosing the active transport.
class TransportModeToggle extends StatelessWidget {
  const TransportModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<LandingCubit, LandingState>(
      buildWhen: (p, c) => p.transferMode != c.transferMode,
      builder: (context, state) {
        return Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Row(
            children: [
              _ModeButton(
                label: s.transport_wifi,
                icon: Icons.wifi_rounded,
                selected: state.transferMode == TransferMode.wifi,
                onTap: () => context
                    .read<LandingCubit>()
                    .setTransferMode(TransferMode.wifi),
              ),
              _ModeButton(
                label: s.transport_bluetooth,
                icon: Icons.bluetooth_rounded,
                selected: state.transferMode == TransferMode.bluetooth,
                onTap: () => context
                    .read<LandingCubit>()
                    .setTransferMode(TransferMode.bluetooth),
              ),
              _ModeButton(
                label: s.transport_guest,
                icon: Icons.qr_code_rounded,
                selected: state.transferMode == TransferMode.guest,
                onTap: () => context
                    .read<LandingCubit>()
                    .setTransferMode(TransferMode.guest),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.amber.withAlpha(25) : null,
            borderRadius: BorderRadius.circular(9),
            border: selected
                ? Border.all(color: AppColors.amber.withAlpha(140))
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected ? AppColors.amber : AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.amber : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
