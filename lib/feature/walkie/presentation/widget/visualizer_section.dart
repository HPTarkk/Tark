import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';
import '../../../audio/api/audio_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// The channel's "radio scope": a recessed oscilloscope screen showing the
/// live waveform, framed by a faint grid and corner ticks, with a status pill
/// that reads out what's on the wire — you're on air, someone's talking (by
/// name), you're muted, or it's just listening.
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
          scope = _Scope(AppColors.textSecondary, s.monitoring, dim: true);
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
          height: 150,
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
                children: [
                  const Positioned.fill(child: _ScanlineBackground()),
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _ScopeGridPainter(
                          gridColor: AppColors.border,
                          tickColor: isActive
                              ? scope.color
                              : AppColors.border,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StatusPill(scope: scope),
                        Expanded(
                          child: StreamBuilder<AudioFrame>(
                            stream: context.read<WalkieTalkieCubit>().frames,
                            builder: (context, snapshot) {
                              final frame = snapshot.data;
                              if (frame == null || frame.samples.isEmpty) {
                                return Center(
                                  child: Text(
                                    state.isReady
                                        ? s.monitoring
                                        : s.initializing,
                                    style: TextStyle(
                                      color: AppColors.textSecondary.withAlpha(
                                        120,
                                      ),
                                      fontSize: 12,
                                      letterSpacing: 3,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                );
                              }
                              return AudioVisualizer(
                                samples: frame.samples,
                                rms: frame.rms,
                                barCount: 52,
                                color: waveColor,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
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

// ── Status pill ───────────────────────────────────────────────────────────────

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

/// Raised pill in the scope's top-left: a status dot (pulsing on air, a
/// slashed mic when muted) plus a short label.
class _StatusPill extends StatefulWidget {
  final _Scope scope;

  const _StatusPill({required this.scope});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.card.withAlpha(235),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(scope.dim ? 70 : 150)),
        boxShadow: scope.dim
            ? null
            : [BoxShadow(color: color.withAlpha(35), blurRadius: 10)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scope.muted)
            Icon(Icons.mic_off_rounded, color: color, size: 11)
          else if (scope.pulse)
            FadeTransition(
              opacity: Tween<double>(begin: 1, end: 0.3).animate(
                CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
              ),
              child: _dot(color, glow: true),
            )
          else
            _dot(color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              scope.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scope.dim ? color.withAlpha(200) : color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dot(Color color, {bool glow = false}) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: glow
          ? [BoxShadow(color: color.withAlpha(160), blurRadius: 6)]
          : null,
    ),
  );
}

// ── Scope grid ────────────────────────────────────────────────────────────────

/// Faint oscilloscope framing painted under the waveform: a centre baseline,
/// a few vertical divisions, and short L-shaped registration ticks in each
/// corner (tinted with the live status colour when active).
class _ScopeGridPainter extends CustomPainter {
  final Color gridColor;
  final Color tickColor;

  const _ScopeGridPainter({required this.gridColor, required this.tickColor});

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor.withAlpha(70)
      ..strokeWidth = 1;

    // Centre baseline.
    final cy = size.height / 2;
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), grid);

    // Vertical divisions (quarters), fainter than the baseline.
    final vgrid = Paint()
      ..color = gridColor.withAlpha(40)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), vgrid);
    }

    // Corner registration ticks.
    const inset = 7.0;
    const len = 9.0;
    final tick = Paint()
      ..color = tickColor.withAlpha(150)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final w = size.width, h = size.height;
    // top-left
    canvas.drawLine(const Offset(inset, inset), const Offset(inset + len, inset), tick);
    canvas.drawLine(const Offset(inset, inset), const Offset(inset, inset + len), tick);
    // top-right
    canvas.drawLine(Offset(w - inset, inset), Offset(w - inset - len, inset), tick);
    canvas.drawLine(Offset(w - inset, inset), Offset(w - inset, inset + len), tick);
    // bottom-left
    canvas.drawLine(Offset(inset, h - inset), Offset(inset + len, h - inset), tick);
    canvas.drawLine(Offset(inset, h - inset), Offset(inset, h - inset - len), tick);
    // bottom-right
    canvas.drawLine(Offset(w - inset, h - inset), Offset(w - inset - len, h - inset), tick);
    canvas.drawLine(Offset(w - inset, h - inset), Offset(w - inset, h - inset - len), tick);
  }

  @override
  bool shouldRepaint(covariant _ScopeGridPainter old) =>
      old.gridColor != gridColor || old.tickColor != tickColor;
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
