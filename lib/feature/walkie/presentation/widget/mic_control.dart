import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';

import '../../../../core/entitlement/license_gate.dart';
import '../../../../core/entitlement/paywall_sheet.dart';
import '../../../../core/entitlement/premium_feature.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/section_header.dart';
import '../../../../core/widget/ticker_text.dart';
import '../manager/walkie_talkie_cubit.dart';

/// One duration/curve for every part of the card, so the tint, the badge, the
/// labels and the chip read as a single flip instead of separate animations
/// that happen to overlap.
const Duration _kDur = Duration(milliseconds: 260);
const Curve _kCurve = Curves.easeOutCubic;

/// Self-mute control — the primary in-channel action.
///
/// This is a hands-free, always-listening radio (VOX auto-transmits when you
/// speak), so the one thing a rider can't otherwise do is temporarily go
/// silent without leaving the channel. This card is that switch: tap to mute
/// your mic, tap again to go live. Music casting is unaffected.
///
/// The whole card animates on toggle — the tint/border slide, the badge icon
/// scale-swaps, and the labels/chip tick over — so the state change reads as
/// one deliberate flip rather than an instant jump.
///
/// The labels tick line by line ([TickerText]) rather than cross-fading as a
/// block. Cross-fading them meant "MIC LIVE" and "MUTED" were both painted, in
/// place, at partial opacity for the whole transition — two different-length
/// strings smeared over each other, with the outgoing line sliding down
/// through the incoming one. Ticking clips each line to its own box and moves
/// one out as the other comes in, so there is never more than one readable
/// word per line.
class MicControl extends StatefulWidget {
  const MicControl({super.key});

  @override
  State<MicControl> createState() => _MicControlState();
}

class _MicControlState extends State<MicControl> {
  final LicenseGate _gate = GetIt.instance<LicenseGate>();
  bool _pressed = false;

  /// Locked only in the live→muted direction: going back on air is never
  /// gated, so a lapsed entitlement can't strand anyone silent. Mirrors the
  /// guard in [WalkieTalkieCubit.toggleSelfMute].
  bool _lockedFor(bool muted) =>
      !muted && !_gate.allows(PremiumFeature.selfMute);

  void _toggle(BuildContext context) {
    final muted = context.read<WalkieTalkieCubit>().state.isSelfMuted;
    if (_lockedFor(muted)) {
      showPaywallSheet(context, PremiumFeature.selfMute);
      return;
    }
    HapticFeedback.selectionClick();
    context.read<WalkieTalkieCubit>().toggleSelfMute();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.mic_section),
        const SizedBox(height: 10),
        BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
          buildWhen: (p, c) => p.isSelfMuted != c.isSelfMuted,
          builder: (context, state) {
            final muted = state.isSelfMuted;
            // Live = green (channel can hear you); muted = red (you're cut off).
            final accent = muted ? AppColors.red : AppColors.green;
            return GestureDetector(
              onTap: () => _toggle(context),
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedScale(
                scale: _pressed ? 0.97 : 1.0,
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: _kDur,
                  curve: _kCurve,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: muted
                        ? Color.alphaBlend(
                            AppColors.red.withAlpha(22),
                            AppColors.card,
                          )
                        : AppColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: muted ? accent.withAlpha(150) : AppColors.border,
                      width: muted ? 1.5 : 1,
                    ),
                    boxShadow: muted
                        ? [
                            BoxShadow(
                              color: accent.withAlpha(30),
                              blurRadius: 18,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    children: [
                      _MicBadge(muted: muted, accent: accent),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TickerText(
                              text: muted
                                  ? s.mic_muted_title
                                  : s.mic_live_title,
                              duration: _kDur,
                              curve: _kCurve,
                              maxLines: 1,
                              textAlign: TextAlign.start,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            TickerText(
                              text: muted
                                  ? s.mic_muted_label
                                  : s.mic_live_label,
                              duration: _kDur,
                              curve: _kCurve,
                              maxLines: 1,
                              textAlign: TextAlign.start,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (_lockedFor(muted)) ...[
                        Icon(
                          Icons.lock_rounded,
                          size: 13,
                          color: AppColors.amber.withAlpha(200),
                        ),
                        const SizedBox(width: 6),
                      ],
                      _ActionChip(muted: muted, accent: accent),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Rounded mic tile: outlined-green with a live mic when open, filled-red with
/// a slashed mic when muted. The box tint animates; the glyph scale-swaps.
class _MicBadge extends StatelessWidget {
  final bool muted;
  final Color accent;

  const _MicBadge({required this.muted, required this.accent});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: _kDur,
      curve: _kCurve,
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: accent.withAlpha(muted ? 40 : 22),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withAlpha(muted ? 170 : 90)),
        boxShadow: muted
            ? [BoxShadow(color: accent.withAlpha(60), blurRadius: 12)]
            : null,
      ),
      child: AnimatedSwitcher(
        duration: _kDur,
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: anim,
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: Icon(
          muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          key: ValueKey(muted),
          color: accent,
          size: 21,
        ),
      ),
    );
  }
}

/// The tap affordance: MUTE (while live) / UNMUTE (while muted).
class _ActionChip extends StatelessWidget {
  final bool muted;
  final Color accent;

  const _ActionChip({required this.muted, required this.accent});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AnimatedContainer(
      duration: _kDur,
      curve: _kCurve,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withAlpha(muted ? 30 : 18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withAlpha(muted ? 140 : 90)),
      ),
      // AnimatedSize absorbs the width difference between MUTE and UNMUTE:
      // the ticker is as wide as both words while one is replacing the other,
      // and without this the chip would snap back the instant the outgoing
      // word is dropped.
      child: AnimatedSize(
        duration: _kDur,
        curve: _kCurve,
        alignment: Alignment.center,
        child: TickerText(
          text: muted ? s.mic_action_unmute : s.mic_action_mute,
          duration: _kDur,
          curve: _kCurve,
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accent,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }
}
