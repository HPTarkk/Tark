import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/section_header.dart';
import '../../../../core/widget/ticker_text.dart';
// Direct file imports (not the audio_api / transfer_api barrels — those
// re-export dart:io code that cannot compile for web).
import '../../../audio/domain/entity/audio_frame.dart';
import '../../../audio/presentation/widget/audio_visualizer.dart';
import '../manager/guest_session_cubit.dart';
import 'guest_settings_toggles.dart';

/// The connected guest's walkie console — the browser twin of the mobile
/// walkie page: identity, live visualizer, TX/RX, the host as a channel
/// member, and the same VOX / noise-filter controls, all driven by
/// [GuestSessionCubit].
class GuestConsole extends StatelessWidget {
  final VoidCallback onLeave;

  const GuestConsole({super.key, required this.onLeave});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ConsoleHeader(),
        const SizedBox(height: 16),
        const _IdentityCard(),
        const SizedBox(height: 16),
        const _VisualizerCard(),
        const SizedBox(height: 14),
        const _LinkBanner(),
        const _StatusRow(),
        const SizedBox(height: 20),
        const _HostMember(),
        const SizedBox(height: 20),
        const _VoxCard(),
        const SizedBox(height: 12),
        const _MicWarning(),
        const SizedBox(height: 8),
        _LeaveButton(onLeave: onLeave),
      ],
    );
  }
}

// ── Header ──────────────────────────────────────────────────────────────────

class _ConsoleHeader extends StatelessWidget {
  const _ConsoleHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amber,
            boxShadow: [
              BoxShadow(color: AppColors.amber.withAlpha(150), blurRadius: 8),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'TARK',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
          ),
        ),
        const Spacer(),
        const GuestSettingsToggles(),
      ],
    );
  }
}

// ── Identity ────────────────────────────────────────────────────────────────

class _IdentityCard extends StatelessWidget {
  const _IdentityCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) => p.myName != c.myName,
      builder: (context, state) => _GlowCard(
        child: Row(
          children: [
            AppAvatar(name: state.myName, isActive: true, size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          state.myName.isEmpty ? '...' : state.myName,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => _showEditName(context, state.myName),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit_rounded,
                                  color: AppColors.amber, size: 12),
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
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.public_rounded,
                          color: AppColors.textSecondary, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        s.transport_guest,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          letterSpacing: 0.5,
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
    );
  }

  void _showEditName(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    final s = context.getString;
    final cubit = context.read<GuestSessionCubit>();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border),
        ),
        title: Text(
          s.set_name_title,
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            counterStyle:
                TextStyle(color: AppColors.textSecondary.withAlpha(120)),
            filled: true,
            fillColor: AppColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.amber),
            ),
          ),
          onSubmitted: (v) {
            cubit.setMyName(v);
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel,
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              cubit.setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(
              s.save,
              style: TextStyle(
                  color: AppColors.amber, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Visualizer ──────────────────────────────────────────────────────────────

class _VisualizerCard extends StatelessWidget {
  const _VisualizerCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) =>
          p.isTalking != c.isTalking ||
          p.hostTalking != c.hostTalking ||
          p.isReady != c.isReady,
      builder: (context, state) {
        final isActive = state.isTalking || state.hostTalking;
        final color = state.isTalking ? AppColors.red : AppColors.amber;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 120,
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive ? color.withAlpha(120) : AppColors.border,
              width: 1.5,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: color.withAlpha(40),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.hardEdge,
          child: StreamBuilder<AudioFrame>(
            stream: context.read<GuestSessionCubit>().frames,
            builder: (context, snapshot) {
              final frame = snapshot.data;
              if (frame == null || frame.samples.isEmpty) {
                return Center(
                  child: Text(
                    state.isReady ? s.monitoring : s.initializing,
                    style: TextStyle(
                      color: AppColors.textSecondary.withAlpha(120),
                      fontSize: 12,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.all(12),
                child: AudioVisualizer(
                  samples: frame.samples,
                  rms: frame.rms,
                  barCount: 48,
                  color: color,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

// ── Link banner ─────────────────────────────────────────────────────────────

class _LinkBanner extends StatelessWidget {
  const _LinkBanner();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) => p.linkUp != c.linkUp,
      builder: (context, state) => AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: state.linkUp
            ? const SizedBox(width: double.infinity)
            : Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 14),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.red.withAlpha(120)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        color: AppColors.red,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.getString.guest_web_link_lost_text,
                        style: TextStyle(
                          color: AppColors.red,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

// ── TX / RX ─────────────────────────────────────────────────────────────────

class _StatusRow extends StatelessWidget {
  const _StatusRow();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) =>
          p.isTalking != c.isTalking || p.hostTalking != c.hostTalking,
      builder: (context, state) => Row(
        children: [
          Expanded(
            child: _StatusChip(
              label: s.tx_label,
              isActive: state.isTalking,
              activeColor: AppColors.red,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _StatusChip(
              label: s.rx_label,
              isActive: state.hostTalking,
              activeColor: AppColors.green,
            ),
          ),
        ],
      ),
    );
  }
}

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
                  ? [
                      BoxShadow(
                          color: activeColor.withAlpha(180), blurRadius: 8)
                    ]
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

// ── Host member ─────────────────────────────────────────────────────────────

class _HostMember extends StatelessWidget {
  const _HostMember();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) =>
          p.hostName != c.hostName || p.hostTalking != c.hostTalking,
      builder: (context, state) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            label: s.channel_members,
            badge: state.isHostOnline ? '1' : null,
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: !state.isHostOnline
                ? Container(
                    key: const ValueKey('empty'),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Center(
                      child: Text(
                        s.connecting,
                        style: TextStyle(
                          color: AppColors.textSecondary.withAlpha(160),
                          fontSize: 13,
                        ),
                      ),
                    ),
                  )
                : Container(
                    key: const ValueKey('host'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: state.hostTalking
                            ? AppColors.green.withAlpha(120)
                            : AppColors.border,
                      ),
                    ),
                    child: Row(
                      children: [
                        AppAvatar(
                            name: state.hostName,
                            isActive: state.hostTalking,
                            size: 40),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            state.hostName,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (state.hostTalking)
                          Row(
                            children: [
                              Icon(Icons.graphic_eq_rounded,
                                  color: AppColors.green, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                s.rx_label,
                                style: TextStyle(
                                  color: AppColors.green,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
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

// ── VOX + noise card ────────────────────────────────────────────────────────

class _VoxCard extends StatelessWidget {
  const _VoxCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) =>
          p.voxThreshold != c.voxThreshold ||
          p.noiseSuppression != c.noiseSuppression,
      builder: (context, state) {
        final cubit = context.read<GuestSessionCubit>();
        final voxPct =
            ((state.voxThreshold / 0.15) * 100).clamp(0.0, 100.0).round();
        final noisePct = (state.noiseSuppression * 100).round();
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
                  _SliderRow(
                    label: s.vox_threshold,
                    valueLabel: '$voxPct%',
                    value: state.voxThreshold,
                    min: 0.0,
                    max: 0.15,
                    onChanged: cubit.setVoxThreshold,
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(s.voice_quiet,
                          style: TextStyle(
                              color: AppColors.textSecondary.withAlpha(160),
                              fontSize: 10,
                              letterSpacing: 1)),
                      Text(s.voice_loud,
                          style: TextStyle(
                              color: AppColors.textSecondary.withAlpha(160),
                              fontSize: 10,
                              letterSpacing: 1)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(color: AppColors.border, height: 1),
                  const SizedBox(height: 12),
                  _SliderRow(
                    label: s.noise_filter,
                    valueLabel:
                        noisePct == 0 ? s.noise_filter_off : '$noisePct%',
                    value: state.noiseSuppression,
                    min: 0.0,
                    max: 1.0,
                    onChanged: cubit.setNoiseSuppression,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(6),
              ),
              child: TickerText(
                text: valueLabel,
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            activeTrackColor: AppColors.amber,
            inactiveTrackColor: AppColors.border,
            thumbColor: AppColors.amber,
            overlayColor: AppColors.amber.withAlpha(40),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

// ── Mic warning ─────────────────────────────────────────────────────────────

class _MicWarning extends StatelessWidget {
  const _MicWarning();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<GuestSessionCubit, GuestSessionState>(
      buildWhen: (p, c) => p.hasPermission != c.hasPermission,
      builder: (context, state) {
        if (state.hasPermission) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.red.withAlpha(25),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.red.withAlpha(100)),
          ),
          child: Row(
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
        );
      },
    );
  }
}

// ── Leave ───────────────────────────────────────────────────────────────────

class _LeaveButton extends StatelessWidget {
  final VoidCallback onLeave;

  const _LeaveButton({required this.onLeave});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return GestureDetector(
      onTap: () => _confirm(context, s),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: AppColors.red.withAlpha(18),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.red.withAlpha(90), width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.power_settings_new_rounded,
                color: AppColors.red.withAlpha(210), size: 18),
            const SizedBox(width: 10),
            Text(
              s.leave_channel,
              style: TextStyle(
                color: AppColors.red.withAlpha(210),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirm(BuildContext context, dynamic s) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: AppColors.border),
        ),
        title: Text(
          s.leave_channel_confirm_title,
          style: TextStyle(
              color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          s.leave_channel_confirm_message,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel,
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onLeave();
            },
            child: Text(
              s.leave,
              style: TextStyle(
                  color: AppColors.red, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared bits ─────────────────────────────────────────────────────────────

class _GlowCard extends StatelessWidget {
  final Widget child;
  const _GlowCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      child: child,
    );
  }
}
