import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/section_header.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../audio/api/audio_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Live VOX status on the walkie page: level meter (with a threshold marker)
/// and a mic-permission warning when denied. The VOX threshold and noise
/// suppression themselves are now set from the Settings page — this stays on
/// the live screen because it's status, not a setting.
class VoxMeter extends StatelessWidget {
  const VoxMeter({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.voxThreshold != c.voxThreshold || p.hasPermission != c.hasPermission,
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(label: s.vox_sensitivity),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: _VoxLevelBar(voxThreshold: state.voxThreshold),
            ),
            if (!state.hasPermission) _MicPermissionWarning(),
          ],
        );
      },
    );
  }
}

// ── Mic permission warning ───────────────────────────────────────────────────

class _MicPermissionWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.red.withAlpha(25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.red.withAlpha(100)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_off_rounded, color: AppColors.red, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.getString.mic_permission_denied,
                  style: TextStyle(color: AppColors.red, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: openAppSettings,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.red.withAlpha(35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.red.withAlpha(140)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.settings_rounded, color: AppColors.red, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    context.getString.open_settings,
                    style: TextStyle(
                      color: AppColors.red,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
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

// ── Level bar ─────────────────────────────────────────────────────────────────

/// Audio-level meter with RTL-aware bar anchoring.
///
/// Uses a [StreamBuilder] so only the meter bar repaints at audio rate, not
/// the entire page.
class _VoxLevelBar extends StatelessWidget {
  final double voxThreshold;

  const _VoxLevelBar({required this.voxThreshold});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return StreamBuilder<AudioFrame>(
      stream: context.read<WalkieTalkieCubit>().frames,
      builder: (context, snapshot) {
        final rms = snapshot.data?.rms ?? 0.0;
        final isActive = rms > voxThreshold;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  s.level_label,
                  style: TextStyle(
                    color: AppColors.textSecondary.withAlpha(160),
                    fontSize: 10,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                TickerText(
                  text: isActive ? s.level_active : s.level_silent,
                  style: TextStyle(
                    color: isActive ? AppColors.red : AppColors.textSecondary.withAlpha(100),
                    fontSize: 10,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) {
                final isRtl = Directionality.of(context) == TextDirection.rtl;
                final w = constraints.maxWidth;
                final rmsNorm = (rms / 0.15).clamp(0.0, 1.0);
                final threshNorm = (voxThreshold / 0.15).clamp(0.0, 1.0);

                return Stack(
                  children: [
                    // Track background
                    Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    // RMS bar — anchored to the leading edge in LTR,
                    // trailing edge in RTL, so AnimatedContainer only
                    // animates width (no position glitch).
                    if (isRtl)
                      Positioned(
                        right: 0,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 50),
                          width: w * rmsNorm,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isActive ? AppColors.red : AppColors.amberDim,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: isActive
                                ? [BoxShadow(color: AppColors.red.withAlpha(150), blurRadius: 6)]
                                : null,
                          ),
                        ),
                      )
                    else
                      Positioned(
                        left: 0,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 50),
                          width: w * rmsNorm,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isActive ? AppColors.red : AppColors.amberDim,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: isActive
                                ? [BoxShadow(color: AppColors.red.withAlpha(150), blurRadius: 6)]
                                : null,
                          ),
                        ),
                      ),
                    // Threshold marker
                    Positioned(
                      left: isRtl ? null : (w * threshNorm - 1).clamp(0.0, w - 2),
                      right: isRtl ? (w * threshNorm - 1).clamp(0.0, w - 2) : null,
                      child: Container(width: 2, height: 8, color: AppColors.textPrimary.withAlpha(200)),
                    ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}
