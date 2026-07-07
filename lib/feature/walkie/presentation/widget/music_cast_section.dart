import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/section_header.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../audio/api/audio_api.dart';
import '../manager/walkie_talkie_cubit.dart';

/// System-audio (music) casting card. Android 10+ only — hidden entirely
/// where playback capture doesn't exist.
///
/// Three faces:
///  * OFF      — pitch line + a big START CASTING call-to-action;
///  * STARTING — the CTA turns into a spinner while the system consent
///               dialog is up;
///  * ON AIR   — glowing card with a live equalizer fed by the actual
///               captured audio, a mix-level slider, and a STOP chip. When
///               the equalizer flatlines (nothing playing, or the player
///               app blocks capture) a hint says why nobody hears music.
class MusicCastSection extends StatelessWidget {
  const MusicCastSection({super.key});

  static final Future<bool> _supported = SystemAudioCapture.isSupported;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _supported,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        final s = context.getString;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 20),
            SectionHeader(label: s.music_cast),
            const SizedBox(height: 12),
            BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
              buildWhen: (p, c) =>
                  p.isSharingSystemAudio != c.isSharingSystemAudio ||
                  p.isStartingSystemAudio != c.isStartingSystemAudio ||
                  p.musicGain != c.musicGain,
              builder: (context, state) {
                final live = state.isSharingSystemAudio;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: live
                        ? Color.alphaBlend(
                            AppColors.amber.withAlpha(14), AppColors.card)
                        : AppColors.card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: live
                          ? AppColors.amber.withAlpha(150)
                          : AppColors.border,
                      width: live ? 1.5 : 1,
                    ),
                    boxShadow: live
                        ? [
                            BoxShadow(
                              color: AppColors.amber.withAlpha(26),
                              blurRadius: 20,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: live
                        ? const _LiveBody()
                        : _IdleBody(
                            starting: state.isStartingSystemAudio,
                          ),
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

// ── OFF / STARTING ───────────────────────────────────────────────────────────

class _IdleBody extends StatelessWidget {
  final bool starting;

  const _IdleBody({required this.starting});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      children: [
        Row(
          children: [
            _MusicBadge(active: false),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                s.music_cast_hint,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: starting
              ? null
              : () =>
                  context.read<WalkieTalkieCubit>().toggleShareSystemAudio(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              color: AppColors.amber.withAlpha(starting ? 12 : 25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.amber.withAlpha(starting ? 60 : 120),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (starting)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      color: AppColors.amber,
                      strokeWidth: 2,
                    ),
                  )
                else
                  Icon(Icons.podcasts_rounded,
                      color: AppColors.amber, size: 17),
                const SizedBox(width: 10),
                Text(
                  starting ? s.music_cast_starting : s.music_cast_start,
                  style: TextStyle(
                    color: AppColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── ON AIR ───────────────────────────────────────────────────────────────────

class _LiveBody extends StatelessWidget {
  const _LiveBody();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final cubit = context.read<WalkieTalkieCubit>();
    return Column(
      children: [
        Row(
          children: [
            _MusicBadge(active: true),
            const SizedBox(width: 12),
            const _OnAirTag(),
            const Spacer(),
            GestureDetector(
              onTap: () => cubit.toggleShareSystemAudio(),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.red.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.red.withAlpha(110)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.stop_rounded, color: AppColors.red, size: 15),
                    const SizedBox(width: 5),
                    Text(
                      s.music_cast_stop,
                      style: TextStyle(
                        color: AppColors.red,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        StreamBuilder<double>(
          stream: cubit.musicLevels,
          initialData: 0,
          builder: (context, snapshot) {
            final level = snapshot.data ?? 0;
            return Column(
              children: [
                _EqualizerBars(level: level),
                // Flatline explainer: capture is running but nothing comes
                // through — music paused, or the player blocks capture.
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  child: level < 0.004
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                color: AppColors.textSecondary.withAlpha(160),
                                size: 13,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  s.music_cast_silent,
                                  style: TextStyle(
                                    color: AppColors.textSecondary
                                        .withAlpha(180),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 14),
        Divider(color: AppColors.border, height: 1),
        const SizedBox(height: 12),
        const _MixLevelControl(),
        const _NotificationAccessHint(),
      ],
    );
  }
}

/// One-time nudge to grant Notification access, so hitting STOP also pauses
/// the source music app (see MediaControl / MediaControlHandler.kt) instead
/// of only tearing down capture. Hidden once access is granted or dismissed;
/// re-checks on resume so it disappears the moment the user grants it.
class _NotificationAccessHint extends StatefulWidget {
  const _NotificationAccessHint();

  static const _dismissedKey = 'music_cast_notif_hint_dismissed';

  @override
  State<_NotificationAccessHint> createState() =>
      _NotificationAccessHintState();
}

class _NotificationAccessHintState extends State<_NotificationAccessHint>
    with WidgetsBindingObserver {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_NotificationAccessHint._dismissedKey) ?? false) {
      if (mounted && _show) setState(() => _show = false);
      return;
    }
    final hasAccess = await MediaControl.hasAccess();
    if (!mounted) return;
    setState(() => _show = !hasAccess);
  }

  Future<void> _dismiss() async {
    setState(() => _show = false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_NotificationAccessHint._dismissedKey, true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final s = context.getString;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: AppColors.textSecondary.withAlpha(160),
            size: 13,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              s.music_cast_stop_hint,
              style: TextStyle(
                color: AppColors.textSecondary.withAlpha(180),
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => MediaControl.requestAccess(),
            child: Text(
              s.music_cast_stop_enable,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _dismiss,
            child: Icon(
              Icons.close_rounded,
              color: AppColors.textSecondary.withAlpha(140),
              size: 14,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pieces ───────────────────────────────────────────────────────────────────

/// Rounded music-note tile; glows amber while casting.
class _MusicBadge extends StatelessWidget {
  final bool active;

  const _MusicBadge({required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(active ? 40 : 20),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: AppColors.amber.withAlpha(active ? 160 : 70),
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: AppColors.amber.withAlpha(60),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: active
            ? AppColors.amber
            : AppColors.amber.withAlpha(170),
        size: 20,
      ),
    );
  }
}

/// Blinking red dot + "ON AIR", broadcast-studio style.
class _OnAirTag extends StatefulWidget {
  const _OnAirTag();

  @override
  State<_OnAirTag> createState() => _OnAirTagState();
}

class _OnAirTagState extends State<_OnAirTag>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.45).animate(
        CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.red,
              boxShadow: [
                BoxShadow(color: AppColors.red.withAlpha(160), blurRadius: 8),
              ],
            ),
          ),
          const SizedBox(width: 7),
          Text(
            s.music_cast_on_air,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 2.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Level-driven equalizer. Bar shape is a fixed pseudo-spectrum (center
/// bump + per-bar jitter) scaled by the live capture level, animated at the
/// capture cadence (~10 Hz) — reacts convincingly to the music without any
/// FFT work on the UI thread.
class _EqualizerBars extends StatelessWidget {
  final double level;

  const _EqualizerBars({required this.level});

  static const _barCount = 27;
  static const _maxBarHeight = 34.0;

  @override
  Widget build(BuildContext context) {
    // Music RMS rarely exceeds ~0.3; stretch it so normal listening levels
    // light up most of the meter.
    final drive = (level * 4.5).clamp(0.0, 1.0);
    return SizedBox(
      height: _maxBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _barCount; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(child: _bar(i, drive)),
          ],
        ],
      ),
    );
  }

  Widget _bar(int index, double drive) {
    // Center-weighted envelope with deterministic per-bar jitter, so the
    // silhouette looks like a spectrum instead of a flat wall.
    final envelope = sin(pi * index / (_barCount - 1));
    final jitter = 0.55 + 0.45 * (((index * 7919) % 100) / 100);
    final height =
        (3.0 + drive * envelope * jitter * (_maxBarHeight - 3.0))
            .clamp(3.0, _maxBarHeight);
    final lit = drive > 0.02;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      height: height,
      decoration: BoxDecoration(
        color: lit
            ? AppColors.amber.withAlpha(120 + (135 * drive * envelope).toInt())
            : AppColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// "MIX LEVEL" slider — how loud the music sits under/over the voice.
class _MixLevelControl extends StatelessWidget {
  const _MixLevelControl();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<WalkieTalkieCubit, WalkieTalkieState>(
      buildWhen: (p, c) => p.musicGain != c.musicGain,
      builder: (context, state) {
        final percent = (state.musicGain * 100).round();
        return Column(
          children: [
            Row(
              children: [
                Icon(Icons.tune_rounded,
                    color: AppColors.textSecondary, size: 14),
                const SizedBox(width: 6),
                Text(
                  s.music_cast_mix,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: TickerText(
                    text: '${percent.localized(context)}%',
                    duration: const Duration(milliseconds: 200),
                    style: TextStyle(
                      color: AppColors.amber,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
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
                value: state.musicGain,
                min: 0.0,
                max: 1.0,
                onChanged: (v) =>
                    context.read<WalkieTalkieCubit>().setMusicGain(v),
              ),
            ),
          ],
        );
      },
    );
  }
}
