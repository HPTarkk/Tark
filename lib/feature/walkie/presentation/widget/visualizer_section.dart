import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../audio/api/audio_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// The channel's "radio dial": a recessed circular scope where the live level
/// radiates from a glowing hub, with a status badge at its centre that reads
/// out what's on the wire — you're on air, someone's talking (by name), you're
/// muted, or it's just listening.
///
/// The outer [BlocBuilder] rebuilds only when transmit/receive/mute/ready
/// state changes. The inner [StreamBuilder] updates the waveform at audio
/// rate without triggering a rebuild of the surrounding UI.
class VisualizerSection extends StatelessWidget {
  const VisualizerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isTransmitting != c.isTransmitting ||
          p.isSomeoneElseTalking != c.isSomeoneElseTalking ||
          p.isSelfMuted != c.isSelfMuted ||
          p.isReady != c.isReady,
      builder: (context, state) {
        final receiving = state.isSomeoneElseTalking;
        final transmitting = state.isTransmitting;
        // Muted only "wins" the look when nothing is actually going out —
        // a music share you started keeps the channel (and the scope) hot.
        final mutedIdle = state.isSelfMuted && !transmitting;

        final _Scope scope;
        if (transmitting) {
          scope = _Scope(AppColors.red, s.mic_on_air, pulse: true);
        } else if (mutedIdle) {
          scope = _Scope(AppColors.red, s.mic_muted_title, muted: true);
        } else if (receiving) {
          scope = _Scope(AppColors.green, _talkerName(state));
        } else {
          scope = _Scope(
            AppColors.textSecondary,
            state.isReady ? s.monitoring : s.initializing,
            dim: true,
          );
        }

        final isActive = transmitting || receiving;
        // Waveform tint: red = you, green = them, gray = muted, amber = idle.
        final waveColor = transmitting
            ? AppColors.red
            : receiving
            ? AppColors.green
            : mutedIdle
            ? AppColors.textSecondary
            : AppColors.amber;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          height: 248,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive ? scope.color.withAlpha(140) : AppColors.border,
              width: 1.5,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: scope.color.withAlpha(45),
                      blurRadius: 22,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          // The recessed "screen": darker than the card so it reads as an
          // inset panel, with the grid/scanlines/waveform layered inside.
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AppColors.border.withAlpha(160)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Positioned.fill(child: _ScanlineBackground()),
                  // The dial idles (a slow shimmer on the ring) before the
                  // first frame arrives, so the scope is never a blank panel.
                  //
                  // While someone else holds the channel the dial follows the
                  // incoming audio, not the mic: it is labelled with their
                  // name, so it has to move with their voice. Your own mic
                  // wins back the dial the moment you key up.
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: StreamBuilder<AudioFrame>(
                        // No key: StreamBuilder resubscribes on a stream swap
                        // by itself, and keeping the element alive keeps the
                        // dial's envelope from snapping back to zero.
                        stream: receiving && !transmitting
                            ? context.read<WalkieTalkieCubit>().receivedFrames
                            : context.read<WalkieTalkieCubit>().frames,
                        builder: (context, snapshot) {
                          final frame = snapshot.data;
                          return AudioVisualizer(
                            samples: frame?.samples ?? const <double>[],
                            rms: frame?.rms ?? 0,
                            barCount: 64,
                            color: waveColor,
                          );
                        },
                      ),
                    ),
                  ),
                  // Status reads out from the hub, inside the ring. No pill
                  // around it: a capsule here cuts a lens-shaped hole through
                  // the bars behind it and the dial stops reading as a dial.
                  // Narrow enough that a long talker name ellipsizes inside the
                  // hub instead of running out over the bars.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 96),
                    child: _StatusReadout(scope: scope),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _talkerName(WalkieTalkieState state) {
    for (final u in state.activeUsers) {
      if (u.isTalking) return u.name;
    }
    return '';
  }
}

// ── Status readout ────────────────────────────────────────────────────────────

/// Value bag describing the current scope status: accent colour, label, and a
/// few flags that pick the leading glyph and its animation.
class _Scope {
  final Color color;
  final String label;
  final bool pulse;
  final bool muted;
  final bool dim;

  const _Scope(
    this.color,
    this.label, {
    this.pulse = false,
    this.muted = false,
    this.dim = false,
  });
}

/// Readout in the dial's hub: a status glyph (a dot, pulsing on air; a slashed
/// mic when muted) over a short label.
class _StatusReadout extends StatefulWidget {
  final _Scope scope;

  const _StatusReadout({required this.scope});

  @override
  State<_StatusReadout> createState() => _StatusReadoutState();
}

class _StatusReadoutState extends State<_StatusReadout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    final color = scope.color;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (scope.muted)
          Icon(Icons.mic_off_rounded, color: color, size: 15)
        else if (scope.pulse)
          FadeTransition(
            opacity: Tween<double>(begin: 1, end: 0.25).animate(
              CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
            ),
            child: _dot(color, glow: true),
          )
        else
          _dot(color),
        const SizedBox(height: 7),
        Text(
          scope.label,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scope.dim ? color.withAlpha(190) : color,
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _dot(Color color, {bool glow = false}) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: glow
          ? [BoxShadow(color: color.withAlpha(160), blurRadius: 7)]
          : null,
    ),
  );
}

// ── Scanline background ───────────────────────────────────────────────────────

class _ScanlineBackground extends StatelessWidget {
  const _ScanlineBackground();

  @override
  Widget build(BuildContext context) {
    // This build reads only static AppColors — no InheritedWidget dependency.
    // The app-level re-key on theme change grafts the preserved element tree
    // back (go_router's GlobalKey'd navigator survives it), and grafted
    // elements are only re-dirtied if they depend on an InheritedWidget — so
    // without listening to the theme directly, this const leaf would keep
    // painting the previous palette's scanlines until the page is recreated.
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (_, _, _) => CustomPaint(
        painter: _ScanlinePainter(AppColors.border.withAlpha(60)),
        size: Size.infinite,
      ),
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  final Color color;

  const _ScanlinePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanlinePainter oldDelegate) =>
      oldDelegate.color != color;
}
