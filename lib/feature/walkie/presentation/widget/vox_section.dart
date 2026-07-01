import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../audio/domain/entity/audio_frame.dart';
import '../../../audio/presentation/manager/audio_cubit.dart';
import '../manager/walkie_talkie_cubit.dart';
import 'user_list.dart';

/// VOX sensitivity section: header, slider, meter, and permission warning.
class VoxSection extends StatelessWidget {
  const VoxSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.voxThreshold != c.voxThreshold,
      builder: (context, state) {
        // Percent reflects the THRESHOLD value directly: 0% at the lowest
        // threshold (most sensitive / effectively always-on), 100% at the
        // highest (least sensitive). Previously this was inverted, so the
        // lowest threshold displayed as 100% — backwards from the "THRESHOLD"
        // label.
        final thresholdPercent =
            ((state.voxThreshold / 0.15) * 100).clamp(0.0, 100.0).toInt();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(label: s.vox_sensitivity),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        s.vox_threshold,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: TickerText(
                          text: '${thresholdPercent.localized(context)}%',
                          duration: const Duration(milliseconds: 200),
                          style: const TextStyle(
                            color: AppColors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      activeTrackColor: AppColors.amber,
                      inactiveTrackColor: AppColors.border,
                      thumbColor: AppColors.amber,
                      overlayColor: AppColors.amber.withAlpha(40),
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 9),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 18),
                    ),
                    child: Slider(
                      value: state.voxThreshold,
                      min: 0.0,
                      max: 0.15,
                      onChanged: (v) =>
                          context.read<WalkieTalkieCubit>().setVoxThreshold(v),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        s.voice_quiet,
                        style: TextStyle(
                          color: AppColors.textSecondary.withAlpha(160),
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                      Text(
                        s.voice_loud,
                        style: TextStyle(
                          color: AppColors.textSecondary.withAlpha(160),
                          fontSize: 10,
                          letterSpacing: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // VoxMeter has its own StreamBuilder — updates at audio-rate
                  // without propagating rebuilds to the rest of the section.
                  VoxMeter(voxThreshold: state.voxThreshold),
                ],
              ),
            ),
            // Permission warning — rebuilt only when hasPermission changes,
            // handled by the parent BlocBuilder on the page.
            BlocBuilder<AudioCubit, AudioStatus>(
              buildWhen: (p, c) => p.hasPermission != c.hasPermission,
              builder: (context, audioState) {
                if (audioState.hasPermission) return const SizedBox.shrink();
                return Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.red.withAlpha(25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.red.withAlpha(100)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.mic_off_rounded,
                        color: AppColors.red,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          context.getString.mic_permission_denied,
                          style: const TextStyle(
                            color: AppColors.red,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

// ── VOX meter ─────────────────────────────────────────────────────────────────

/// Audio-level meter with RTL-aware bar anchoring.
///
/// Uses a [StreamBuilder] so only the meter bar repaints at audio rate, not
/// the entire VOX section.
class VoxMeter extends StatelessWidget {
  final double voxThreshold;

  const VoxMeter({super.key, required this.voxThreshold});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return StreamBuilder<AudioFrame>(
      stream: context.read<AudioCubit>().frames,
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
                Text(
                  isActive ? s.level_active : s.level_silent,
                  style: TextStyle(
                    color: isActive
                        ? AppColors.red
                        : AppColors.textSecondary.withAlpha(100),
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
                final isRtl =
                    Directionality.of(context) == TextDirection.rtl;
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
                            color:
                                isActive ? AppColors.red : AppColors.amberDim,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: isActive
                                ? [
                                    BoxShadow(
                                      color: AppColors.red.withAlpha(150),
                                      blurRadius: 6,
                                    ),
                                  ]
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
                            color:
                                isActive ? AppColors.red : AppColors.amberDim,
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: isActive
                                ? [
                                    BoxShadow(
                                      color: AppColors.red.withAlpha(150),
                                      blurRadius: 6,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                    // Threshold marker
                    Positioned(
                      left: isRtl
                          ? null
                          : (w * threshNorm - 1).clamp(0.0, w - 2),
                      right: isRtl
                          ? (w * threshNorm - 1).clamp(0.0, w - 2)
                          : null,
                      child: Container(
                        width: 2,
                        height: 8,
                        color: AppColors.textPrimary.withAlpha(200),
                      ),
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
