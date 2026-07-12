import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/app_localizations.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../transfer/api/transfer_api.dart';
import '../manager/onboarding_cubit.dart';
import 'onboarding_emblem.dart';

/// Beat 4 — the payoff: the callsign and transport picked in the previous
/// beats assemble into the operator card the user will meet on the landing
/// page — stamped READY, with a periodic holographic gloss sweeping across
/// it like light catching a laminated ID — plus two tips worth knowing on
/// day one.
class ReadyStep extends StatelessWidget {
  final Animation<double> reveal;

  /// 0..1 gloss-glint loop shared with the page CTA.
  final Animation<double> shimmer;

  const ReadyStep({super.key, required this.reveal, required this.shimmer});

  String _modeLabel(AppLocalizations s, TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => s.transport_wifi_hotspot,
    TransferMode.bluetooth => s.transport_bluetooth,
    TransferMode.guest => s.transport_guest,
  };

  IconData _modeIcon(TransferMode mode) => switch (mode) {
    TransferMode.wifi || TransferMode.hotspot => Icons.wifi_rounded,
    TransferMode.bluetooth => Icons.bluetooth_rounded,
    TransferMode.guest => Icons.qr_code_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<OnboardingCubit, OnboardingState>(
      builder: (context, state) {
        final tips = [
          (Icons.graphic_eq_rounded, s.onboarding_tip_vox),
          (Icons.tune_rounded, s.onboarding_tip_settings),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StaggeredItem(
              reveal: reveal,
              index: 0,
              count: 5,
              child: Text(
                s.onboarding_ready_title,
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
              count: 5,
              child: Text(
                s.onboarding_ready_sub,
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
              count: 5,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _HoloGloss(
                    shimmer: shimmer,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppColors.amber.withAlpha(120),
                          width: 1.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.amber.withAlpha(25),
                            blurRadius: 20,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          AppAvatar(name: state.name.trim(), size: 52),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  state.name.trim().isEmpty
                                      ? '...'
                                      : state.name.trim(),
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 5),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _modeIcon(state.mode),
                                      size: 13,
                                      color: AppColors.textSecondary,
                                    ),
                                    const SizedBox(width: 5),
                                    Flexible(
                                      child: Text(
                                        _modeLabel(s, state.mode),
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: -12,
                    end: 14,
                    child: _ReadyStamp(reveal: reveal),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            for (final (i, tip) in tips.indexed) ...[
              if (i > 0) const SizedBox(height: 10),
              StaggeredItem(
                reveal: reveal,
                index: 3 + i,
                count: 5,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(tip.$1, color: AppColors.amber, size: 15),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        tip.$2,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The payoff moment: a rubber-stamp "READY" seal that slams onto the
/// operator card — riding the tail of the beat's reveal so it lands after
/// the card has assembled, overshooting slightly like a real stamp.
class _ReadyStamp extends StatelessWidget {
  final Animation<double> reveal;

  const _ReadyStamp({required this.reveal});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    final slam = CurvedAnimation(
      parent: reveal,
      curve: const Interval(0.72, 1.0, curve: Curves.easeOutBack),
    );
    return AnimatedBuilder(
      animation: slam,
      builder: (_, child) {
        final t = slam.value;
        if (t <= 0) return const SizedBox.shrink();
        return Opacity(
          // easeOutBack overshoots past 1 — the scale may, opacity must not.
          opacity: t.clamp(0.0, 1.0),
          child: Transform.rotate(
            angle: -0.16,
            child: Transform.scale(scale: 2.2 - 1.2 * t, child: child),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.background.withAlpha(200),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.amber, width: 2),
          boxShadow: [
            BoxShadow(color: AppColors.amber.withAlpha(70), blurRadius: 12),
          ],
        ),
        child: Text(
          s.onboarding_stamp_ready,
          style: TextStyle(
            color: AppColors.amber,
            fontSize: 11,
            fontWeight: FontWeight.w900,
            // Persian is a joined script — tracking stays latin-only.
            letterSpacing: isFa ? 0.5 : 3,
          ),
        ),
      ),
    );
  }
}

/// Periodic holographic gloss across the operator card — a soft diagonal
/// light band sweeping over part of the loop, like an ID card catching
/// light. Rendered srcATop so it only tints the card's own pixels.
class _HoloGloss extends StatelessWidget {
  final Animation<double> shimmer;
  final Widget child;

  const _HoloGloss({required this.shimmer, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shimmer,
      child: child,
      builder: (_, prebuilt) {
        final glossT = Curves.easeInOut.transform(
          ((shimmer.value - 0.55) / 0.45).clamp(0.0, 1.0),
        );
        final dx = -1.8 + 3.6 * glossT;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment(dx - 0.7, -1),
            end: Alignment(dx + 0.7, 1),
            colors: [
              const Color(0x00FFFFFF),
              Colors.white.withAlpha(34),
              const Color(0x00FFFFFF),
            ],
          ).createShader(rect),
          child: prebuilt,
        );
      },
    );
  }
}
