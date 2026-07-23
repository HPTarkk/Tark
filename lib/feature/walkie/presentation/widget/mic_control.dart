import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/section_header.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Self-mute control — the primary in-channel action.
///
/// This is a hands-free, always-listening radio (VOX auto-transmits when you
/// speak), so the one thing a rider can't otherwise do is temporarily go
/// silent without leaving the channel. This card is that switch: tap to mute
/// your mic, tap again to go live. Music casting is unaffected.
///
/// The whole card animates on toggle — the tint/border slide, the badge icon
/// scale-swaps, and the labels/chip cross-fade — so the state change reads as
/// one deliberate flip rather than an instant jump.
class MicControl extends StatefulWidget {
  const MicControl({super.key});

  @override
  State<MicControl> createState() => _MicControlState();
}

class _MicControlState extends State<MicControl> {
  bool _pressed = false;

  static const _dur = Duration(milliseconds: 260);
  static const _curve = Curves.easeOutCubic;

  void _toggle(BuildContext context) {
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
                  duration: _dur,
                  curve: _curve,
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
                        child: AnimatedSwitcher(
                          duration: _dur,
                          switchInCurve: _curve,
                          switchOutCurve: _curve,
                          transitionBuilder: _slideFade,
                          layoutBuilder: _topLeftLayout,
                          child: Column(
                            key: ValueKey(muted),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                muted ? s.mic_muted_title : s.mic_live_title,
                                style: TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                muted ? s.mic_muted_label : s.mic_live_label,
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
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

  // Slide-up + fade for the label swap.
  static Widget _slideFade(Widget child, Animation<double> anim) =>
      FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.28),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      );

  // Keep swapped labels pinned top-left so they don't drift centre mid-switch.
  static Widget _topLeftLayout(Widget? current, List<Widget> previous) => Stack(
    alignment: Alignment.centerLeft,
    children: [
      ...previous,
      ?current,
    ],
  );
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
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
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
        duration: const Duration(milliseconds: 260),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
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
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withAlpha(muted ? 30 : 18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withAlpha(muted ? 140 : 90)),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: Text(
          muted ? s.mic_action_unmute : s.mic_action_mute,
          key: ValueKey(muted),
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
