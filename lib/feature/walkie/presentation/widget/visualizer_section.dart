import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../audio/api/audio_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// Isolated visualizer card.
///
/// The outer [BlocBuilder] rebuilds only when transmit/receive/ready state
/// changes. The inner [StreamBuilder] updates the waveform at audio rate
/// without triggering a rebuild of the surrounding UI.
class VisualizerSection extends StatelessWidget {
  const VisualizerSection({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) =>
          p.isTransmitting != c.isTransmitting ||
          p.isSomeoneElseTalking != c.isSomeoneElseTalking ||
          p.isReady != c.isReady,
      builder: (context, state) {
        final isActive = state.isTransmitting || state.isSomeoneElseTalking;
        final color = state.isTransmitting ? AppColors.red : AppColors.amber;
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
          child: Stack(
            children: [
              const _ScanlineBackground(),
              StreamBuilder<AudioFrame>(
                stream: context.read<WalkieTalkieCubit>().frames,
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
            ],
          ),
        );
      },
    );
  }
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
        painter: _ScanlinePainter(AppColors.border.withAlpha(80)),
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
