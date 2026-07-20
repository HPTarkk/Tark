import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/settings_category_card.dart';

/// Advanced/technical settings, split off the main Settings page so casual
/// users never meet them: the noise-cleaner engine choice and the playback
/// (jitter-buffer) delay.
///
/// Same live-session threading as [SettingsPage]: [buildPage] accepts the
/// already-running [WalkieTalkieCubit] via go_router's `extra` so the engine
/// choice applies to an active channel instantly.
class AdvancedSettingsPage extends StatefulWidget {
  const AdvancedSettingsPage._();

  static Widget buildPage({Object? liveSession}) => BlocProvider<SettingsCubit>(
    create: (_) => SettingsCubit(
      liveSession: liveSession as WalkieTalkieCubit?,
      repository: GetIt.instance<SettingsRepository>(),
    ),
    child: const AdvancedSettingsPage._(),
  );

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage>
    with TickerProviderStateMixin {
  // Staggered entrance, same pattern as the main Settings page:
  // [voice, noise cleaner, delay]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  static const _sectionCount = 3;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final starts = List.generate(_sectionCount, (i) => i * 0.6 / _sectionCount);
    _sections = starts
        .map(
          (s) => CurvedAnimation(
            parent: _entranceController,
            curve: Interval(
              s,
              (s + 0.4).clamp(0.0, 1.0),
              curve: Curves.easeOutCubic,
            ),
          ),
        )
        .toList();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _entranceController.forward(),
    );
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  Widget _entrance(int index, Widget child) => AnimatedBuilder(
    animation: _sections[index],
    child: child,
    builder: (_, prebuilt) => Opacity(
      opacity: _sections[index].value,
      child: Transform.translate(
        offset: Offset(0, 18 * (1 - _sections[index].value)),
        child: prebuilt,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppColors.systemOverlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
            onPressed: () => context.pop(),
          ),
          title: Text(
            s.settings_advanced_title,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _entrance(0, _VoiceCard()),
                const SizedBox(height: 16),
                _entrance(1, _NoiseCleanerCard()),
                const SizedBox(height: 16),
                _entrance(2, _DelayCard()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Voice & Audio (VOX threshold + noise filter) ────────────────────────────

class _VoiceCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.graphic_eq_rounded,
      title: s.settings_section_voice,
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) =>
            p.voxThreshold != c.voxThreshold ||
            p.noiseSuppression != c.noiseSuppression ||
            p.isLive != c.isLive,
        builder: (context, state) {
          final thresholdPercent = ((state.voxThreshold / 0.15) * 100)
              .clamp(0.0, 100.0)
              .toInt();
          final noisePercent = (state.noiseSuppression * 100).round();
          final noiseLabel = noisePercent == 0
              ? s.noise_filter_off
              : '${noisePercent.localized(context)}%';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                _AppliesHint(
                  live: state.isLive,
                  text: state.isLive
                      ? s.settings_applies_live
                      : s.settings_applies_next_session,
                ),
                const SizedBox(height: 12),
                _sliderHeader(
                  s.vox_threshold,
                  '${thresholdPercent.localized(context)}%',
                ),
                SliderTheme(
                  data: _sliderTheme(context),
                  child: Slider(
                    value: state.voxThreshold,
                    min: 0.0,
                    max: 0.15,
                    onChanged: (v) =>
                        context.read<SettingsCubit>().setVoxThreshold(v),
                    onChangeEnd: (_) => HapticFeedback.selectionClick(),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.voice_quiet, style: _hintStyle),
                    Text(s.voice_loud, style: _hintStyle),
                  ],
                ),
                const SizedBox(height: 10),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 14),
                _sliderHeader(
                  s.noise_filter,
                  noiseLabel,
                  active: noisePercent != 0,
                ),
                SliderTheme(
                  data: _sliderTheme(context),
                  child: Slider(
                    value: state.noiseSuppression.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) =>
                        context.read<SettingsCubit>().setNoiseSuppression(v),
                    onChangeEnd: (_) => HapticFeedback.selectionClick(),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.noise_filter_weak, style: _hintStyle),
                    Text(s.noise_filter_strong, style: _hintStyle),
                  ],
                ),
                const SizedBox(height: 10),
                _RestoreDefaultsButton(),
              ],
            ),
          );
        },
      ),
    );
  }

  static TextStyle get _hintStyle => TextStyle(
    color: AppColors.textSecondary.withAlpha(160),
    fontSize: 10,
    letterSpacing: 1,
  );

  Widget _sliderHeader(String label, String value, {bool active = true}) => Row(
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
      Builder(
        builder: (context) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.border,
            borderRadius: BorderRadius.circular(6),
          ),
          child: TickerText(
            text: value,
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: active ? AppColors.amber : AppColors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ],
  );

  SliderThemeData _sliderTheme(BuildContext context) =>
      SliderTheme.of(context).copyWith(
        trackHeight: 4,
        activeTrackColor: AppColors.amber,
        inactiveTrackColor: AppColors.border,
        thumbColor: AppColors.amber,
        overlayColor: AppColors.amber.withAlpha(40),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      );
}

class _RestoreDefaultsButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        context.read<SettingsCubit>().restoreVoiceDefaults();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(s.settings_restore_defaults_done),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.amber.withAlpha(18),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.amber.withAlpha(110)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.restart_alt_rounded, color: AppColors.amber, size: 16),
            const SizedBox(width: 8),
            Text(
              s.settings_restore_defaults,
              style: TextStyle(
                color: AppColors.amber,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Noise cleaner (3-way engine choice) ─────────────────────────────────────

class _NoiseCleanerCard extends StatelessWidget {
  // Both platforms have the native (RNNoise) plugin wired — Android is
  // verified end-to-end, iOS is wired but unbuilt/untested so far. Any other
  // platform (web, desktop) has no native build path at all, so it silently
  // falls back to spectral in AudioEngineImpl — disable picking it there
  // instead of offering a choice that no-ops.
  bool get _smartAvailable => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.auto_awesome_rounded,
      title: s.noise_cleaner_section,
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) =>
            p.noiseSuppressionEngine != c.noiseSuppressionEngine ||
            p.isLive != c.isLive,
        builder: (context, state) {
          // A platform with no native build path can't run rnnoise
          // regardless of the stored preference — show what's really
          // running, not a selected-but-disabled option that misrepresents
          // the active engine.
          final effectiveEngine = _smartAvailable
              ? state.noiseSuppressionEngine
              : NoiseSuppressionEngine.spectral;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AppliesHint(
                  live: state.isLive,
                  text: state.isLive
                      ? s.settings_applies_live
                      : s.settings_applies_next_session,
                ),
                const SizedBox(height: 10),
                Text(
                  s.noise_cleaner_intro,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                _CleanerOption(
                  icon: Icons.graphic_eq_rounded,
                  title: s.noise_cleaner_simple_title,
                  description: s.noise_cleaner_simple_desc,
                  downside: s.noise_cleaner_simple_downside,
                  selected: effectiveEngine == NoiseSuppressionEngine.spectral,
                  onTap: () => _select(context, NoiseSuppressionEngine.spectral),
                ),
                const SizedBox(height: 10),
                _CleanerOption(
                  icon: Icons.auto_awesome_rounded,
                  title: s.noise_cleaner_smart_title,
                  description: s.noise_cleaner_smart_desc,
                  downside: s.noise_cleaner_smart_downside,
                  selected: effectiveEngine == NoiseSuppressionEngine.rnnoise,
                  enabled: _smartAvailable,
                  onTap: () => _select(context, NoiseSuppressionEngine.rnnoise),
                ),
                const SizedBox(height: 10),
                _CleanerOption(
                  icon: Icons.layers_rounded,
                  title: s.noise_cleaner_both_title,
                  description: s.noise_cleaner_both_desc,
                  downside: s.noise_cleaner_both_downside,
                  selected: effectiveEngine == NoiseSuppressionEngine.both,
                  enabled: _smartAvailable,
                  onTap: () => _select(context, NoiseSuppressionEngine.both),
                ),
                if (!_smartAvailable) ...[
                  const SizedBox(height: 10),
                  Text(
                    s.noise_cleaner_unavailable,
                    style: TextStyle(
                      color: AppColors.textSecondary.withAlpha(180),
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _select(BuildContext context, NoiseSuppressionEngine engine) {
    HapticFeedback.selectionClick();
    context.read<SettingsCubit>().setNoiseSuppressionEngine(engine);
  }
}

/// One selectable noise-cleaner choice: plain-words title + what it does,
/// with its trade-off spelled out right below so the cost of the benefit is
/// never hidden.
class _CleanerOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final String downside;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _CleanerOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.downside,
    required this.selected,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final active = selected && enabled;
    final titleColor = !enabled
        ? AppColors.textSecondary.withAlpha(110)
        : AppColors.textPrimary;
    final bodyColor = enabled
        ? AppColors.textSecondary
        : AppColors.textSecondary.withAlpha(110);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: active ? AppColors.amber.withAlpha(20) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.amber.withAlpha(150) : AppColors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: active ? AppColors.amber : bodyColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  active
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 18,
                  color: active
                      ? AppColors.amber
                      : AppColors.textSecondary.withAlpha(enabled ? 140 : 80),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(color: bodyColor, fontSize: 11.5, height: 1.4),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 12,
                  color: bodyColor.withAlpha(enabled ? 190 : 110),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${s.noise_cleaner_downside_label}: ',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: downside),
                      ],
                    ),
                    style: TextStyle(
                      color: bodyColor.withAlpha(enabled ? 190 : 110),
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Playback delay (jitter buffer) ──────────────────────────────────────────

class _DelayCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.schedule_rounded,
      title: s.settings_delay,
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) => p.targetBufferMs != c.targetBufferMs,
        builder: (context, state) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The jitter buffer never rebuilds mid-call, so unlike the
              // noise cleaner this one always waits for the next session.
              _AppliesHint(live: false, text: s.settings_applies_next_session),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    s.settings_delay,
                    style: TextStyle(
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
                      text: '${state.targetBufferMs} ms',
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
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 9,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 18,
                  ),
                ),
                child: Slider(
                  value: state.targetBufferMs.toDouble().clamp(60, 300),
                  min: 60,
                  max: 300,
                  divisions: 24,
                  onChanged: (v) =>
                      context.read<SettingsCubit>().setTargetBufferMs(
                        v.round(),
                      ),
                  onChangeEnd: (_) => HapticFeedback.selectionClick(),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s.settings_delay_low_hint, style: _hintStyle),
                  Text(s.settings_delay_high_hint, style: _hintStyle),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  s.settings_delay_desc,
                  style: TextStyle(
                    color: AppColors.textSecondary.withAlpha(180),
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static TextStyle get _hintStyle => TextStyle(
    color: AppColors.textSecondary.withAlpha(160),
    fontSize: 10,
    letterSpacing: 1,
  );
}

// ── Shared bits ─────────────────────────────────────────────────────────────

/// "Applies instantly / next session" note, same look as the one on the main
/// Settings page's voice card.
class _AppliesHint extends StatelessWidget {
  final bool live;
  final String text;

  const _AppliesHint({required this.live, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          live ? Icons.podcasts_rounded : Icons.schedule_rounded,
          color: AppColors.textSecondary.withAlpha(160),
          size: 12,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: AppColors.textSecondary.withAlpha(180),
              fontSize: 10.5,
            ),
          ),
        ),
      ],
    );
  }
}
