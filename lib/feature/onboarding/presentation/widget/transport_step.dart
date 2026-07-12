import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_event.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'onboarding_emblem.dart';

/// Beat 2 — choose how peers connect. Three cards, one per transport
/// family; the selected card carries a breathing amber glow driven by the
/// page's shared [pulse] clock.
class TransportStep extends StatelessWidget {
  final Animation<double> reveal;
  final Animation<double> pulse;

  const TransportStep({super.key, required this.reveal, required this.pulse});

  static bool _isWifiGroup(TransferMode mode) =>
      mode == TransferMode.wifi || mode == TransferMode.hotspot;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      buildWhen: (p, c) => p.mode != c.mode,
      builder: (context, state) {
        final cubit = context.read<OnboardingCubit>();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StaggeredItem(
              reveal: reveal,
              index: 0,
              count: 6,
              child: Text(
                s.onboarding_mode_title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(height: 8),
            StaggeredItem(
              reveal: reveal,
              index: 1,
              count: 6,
              child: Text(
                s.onboarding_mode_help,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary.withAlpha(180),
                  fontSize: 11.5,
                ),
              ),
            ),
            const SizedBox(height: 18),
            StaggeredItem(
              reveal: reveal,
              index: 2,
              count: 6,
              child: _ModeCard(
                icon: Icons.wifi_rounded,
                title: s.transport_wifi_hotspot,
                description: s.onboarding_mode_wifi_desc,
                selected: _isWifiGroup(state.mode),
                pulse: pulse,
                // Keep an existing hotspot choice intact, same rule as the
                // Settings picker — only switch when coming from another
                // family entirely.
                onTap: () => _select(
                  cubit,
                  _isWifiGroup(state.mode) ? state.mode : TransferMode.wifi,
                ),
              ),
            ),
            const SizedBox(height: 10),
            StaggeredItem(
              reveal: reveal,
              index: 3,
              count: 6,
              child: _ModeCard(
                icon: Icons.bluetooth_rounded,
                title: s.transport_bluetooth,
                description: s.onboarding_mode_bluetooth_desc,
                selected: state.mode == TransferMode.bluetooth,
                pulse: pulse,
                onTap: () => _select(cubit, TransferMode.bluetooth),
              ),
            ),
            const SizedBox(height: 10),
            StaggeredItem(
              reveal: reveal,
              index: 4,
              count: 6,
              child: _ModeCard(
                icon: Icons.qr_code_rounded,
                title: s.transport_guest,
                description: s.onboarding_mode_guest_desc,
                selected: state.mode == TransferMode.guest,
                pulse: pulse,
                onTap: () => _select(cubit, TransferMode.guest),
              ),
            ),
          ],
        );
      },
    );
  }

  void _select(OnboardingCubit cubit, TransferMode mode) {
    HapticFeedback.selectionClick();
    Sfx.play(SfxEvent.toggle);
    cubit.selectMode(mode);
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool selected;
  final Animation<double> pulse;
  final VoidCallback onTap;

  const _ModeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.pulse,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedBuilder(
        animation: pulse,
        builder: (_, child) => AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: selected ? AppColors.amber.withAlpha(20) : AppColors.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? AppColors.amber.withAlpha((150 + 80 * pulse.value).toInt())
                  : AppColors.border,
              width: selected ? 1.6 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: AppColors.amber.withAlpha(
                        (20 + 30 * pulse.value).toInt(),
                      ),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              // The selected icon breathes with the card's glow — the one
              // live element inside each card.
              Transform.scale(
                scale: selected ? 1 + 0.08 * pulse.value : 1,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.amber.withAlpha(35)
                        : AppColors.border.withAlpha(90),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: selected ? AppColors.amber : AppColors.textSecondary,
                    size: 20,
                  ),
                ),
              ),
              Expanded(child: child!),
            ],
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: selected ? AppColors.amber : AppColors.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                key: ValueKey(selected),
                color: selected
                    ? AppColors.amber
                    : AppColors.textSecondary.withAlpha(120),
                size: 20,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
