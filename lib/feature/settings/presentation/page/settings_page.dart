import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/language_toggle.dart';
import '../../../../core/widget/section_header.dart';
import '../../../../core/widget/theme_toggle.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/settings_row.dart';

/// Consolidated Settings/Profile page — identity, VOX/noise, sound cues,
/// appearance, and the quick-access toggle, all in one place instead of
/// scattered across Landing and the live Walkie page.
///
/// [buildPage] accepts an optional already-running [WalkieTalkieCubit]
/// (passed via go_router's `extra` by whoever navigates here) so changes
/// apply live to an active channel — see [SettingsCubit].
class SettingsPage extends StatefulWidget {
  const SettingsPage._();

  static Widget buildPage({Object? liveSession}) => BlocProvider<SettingsCubit>(
        create: (_) =>
            SettingsCubit(liveSession: liveSession as WalkieTalkieCubit?),
        child: const SettingsPage._(),
      );

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with TickerProviderStateMixin {
  // Staggered entrance, same pattern as landing/walkie pages: [identity,
  // voice, sound, appearance, connection]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    const starts = [0.0, 0.15, 0.32, 0.5, 0.68];
    _sections = starts
        .map(
          (s) => CurvedAnimation(
            parent: _entranceController,
            curve: Interval(s, (s + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutCubic),
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
            s.settings_title,
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
                _entrance(0, _IdentitySection()),
                const SizedBox(height: 22),
                _entrance(1, _VoiceSection()),
                const SizedBox(height: 22),
                _entrance(2, _SoundSection()),
                const SizedBox(height: 22),
                _entrance(3, _AppearanceSection()),
                const SizedBox(height: 22),
                _entrance(4, _ConnectionSection()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Shared card chrome ──────────────────────────────────────────────────────

class _SettingsCard extends StatelessWidget {
  final Widget child;
  const _SettingsCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}

// ── Identity ─────────────────────────────────────────────────────────────────

class _IdentitySection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.settings_section_identity),
        const SizedBox(height: 10),
        BlocBuilder<SettingsCubit, SettingsState>(
          buildWhen: (p, c) => p.myName != c.myName,
          builder: (context, state) => _SettingsCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  AppAvatar(name: state.myName, size: 48),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      state.myName.isEmpty ? '...' : state.myName,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _showEditNameDialog(context, state.myName);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_rounded, color: AppColors.amber, size: 14),
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
            ),
          ),
        ),
      ],
    );
  }

  void _showEditNameDialog(BuildContext context, String currentName) {
    final controller = TextEditingController(text: currentName);
    final cubit = context.read<SettingsCubit>();
    final s = context.getString;
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
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            counterStyle: TextStyle(color: AppColors.textSecondary.withAlpha(120)),
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
            child: Text(s.cancel, style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              cubit.setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(
              s.save,
              style: TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Voice (VOX + noise) ──────────────────────────────────────────────────────

class _VoiceSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.settings_section_voice),
        const SizedBox(height: 10),
        BlocBuilder<SettingsCubit, SettingsState>(
          buildWhen: (p, c) =>
              p.voxThreshold != c.voxThreshold ||
              p.noiseSuppression != c.noiseSuppression ||
              p.isLive != c.isLive,
          builder: (context, state) {
            final thresholdPercent =
                ((state.voxThreshold / 0.15) * 100).clamp(0.0, 100.0).toInt();
            final noisePercent = (state.noiseSuppression * 100).round();
            final noiseLabel =
                noisePercent == 0 ? s.noise_filter_off : '${noisePercent.localized(context)}%';
            return _SettingsCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          state.isLive
                              ? Icons.podcasts_rounded
                              : Icons.schedule_rounded,
                          color: AppColors.textSecondary.withAlpha(160),
                          size: 12,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            state.isLive
                                ? s.settings_applies_live
                                : s.settings_applies_next_session,
                            style: TextStyle(
                              color: AppColors.textSecondary.withAlpha(180),
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _sliderHeader(s.vox_threshold, '${thresholdPercent.localized(context)}%'),
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
                    _sliderHeader(s.noise_filter, noiseLabel, active: noisePercent != 0),
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
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            );
          },
        ),
      ],
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

  SliderThemeData _sliderTheme(BuildContext context) => SliderTheme.of(context).copyWith(
        trackHeight: 4,
        activeTrackColor: AppColors.amber,
        inactiveTrackColor: AppColors.border,
        thumbColor: AppColors.amber,
        overlayColor: AppColors.amber.withAlpha(40),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
      );
}

// ── Sound & alerts ───────────────────────────────────────────────────────────

class _SoundSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.settings_section_sound),
        const SizedBox(height: 10),
        _SettingsCard(
          child: ValueListenableBuilder<bool>(
            valueListenable: Sfx.enabled,
            builder: (context, enabled, _) => SettingsRow(
              icon: enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              label: s.sfx_feedback,
              trailing: Switch(
                value: enabled,
                activeThumbColor: AppColors.amber,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  Sfx.setEnabled(v);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Appearance ───────────────────────────────────────────────────────────────

class _AppearanceSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.settings_section_appearance),
        const SizedBox(height: 10),
        _SettingsCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                const ThemeToggle(),
                const SizedBox(height: 16),
                const LanguageToggle(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Connection ───────────────────────────────────────────────────────────────

class _ConnectionSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(label: s.settings_section_connection),
        const SizedBox(height: 10),
        _SettingsCard(
          child: BlocBuilder<SettingsCubit, SettingsState>(
            buildWhen: (p, c) => p.quickAccessEnabled != c.quickAccessEnabled,
            builder: (context, state) => SettingsRow(
              icon: Icons.bolt_rounded,
              label: s.settings_quick_access,
              subtitle: s.settings_quick_access_desc,
              trailing: Switch(
                value: state.quickAccessEnabled,
                activeThumbColor: AppColors.amber,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  context.read<SettingsCubit>().setQuickAccessEnabled(v);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
