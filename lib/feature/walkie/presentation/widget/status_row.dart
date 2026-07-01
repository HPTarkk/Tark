import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../manager/walkie_talkie_cubit.dart';

/// TX / RX status indicators row.
class StatusRow extends StatelessWidget {
  const StatusRow({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isTransmitting != c.isTransmitting ||
          p.isSomeoneElseTalking != c.isSomeoneElseTalking,
      builder: (context, state) => Row(
        children: [
          Expanded(
            child: _StatusChip(
              label: context.getString.tx_label,
              isActive: state.isTransmitting,
              activeColor: AppColors.red,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatusChip(
              label: context.getString.rx_label,
              isActive: state.isSomeoneElseTalking,
              activeColor: AppColors.green,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status chip ───────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final Color activeColor;

  const _StatusChip({
    required this.label,
    required this.isActive,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isActive ? activeColor.withAlpha(30) : AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? activeColor : AppColors.border,
          width: 1.5,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? activeColor : AppColors.border,
              boxShadow: isActive
                  ? [BoxShadow(color: activeColor.withAlpha(180), blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: isActive ? activeColor : AppColors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w800,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
    );
  }
}
