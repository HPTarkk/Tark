import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/analytics/analytics.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/settings/noise_suppression_engine.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/widget/ticker_text.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/diagnostics_card.dart';
import '../widget/settings_category_card.dart';
import '../widget/settings_row.dart';
import '../widget/transport_mode_picker.dart';

/// Advanced/technical settings, split off the main Settings page so casual
/// users never meet them: the noise-cleaner engine choice, the playback
/// (jitter-buffer) delay, and the diagnostic log.
///
/// The log belongs here rather than on the main page for the same reason as
/// the rest of it — nobody goes looking for it on an ordinary day, and the
/// people who do need it have been pointed at it.
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
      analytics: GetIt.instance<Analytics>(),
    ),
    child: const AdvancedSettingsPage._(),
  );

  @override
  State<AdvancedSettingsPage> createState() => _AdvancedSettingsPageState();
}

class _AdvancedSettingsPageState extends State<AdvancedSettingsPage>
    with TickerProviderStateMixin {
  // Staggered entrance, same pattern as the main Settings page:
  // [transport, voice, HD audio, noise cleaner, delay, diagnostics]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  static const _sectionCount = 6;

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
                _entrance(0, _TransportCard()),
                const SizedBox(height: 16),
                _entrance(1, _VoiceCard()),
                const SizedBox(height: 16),
                _entrance(2, const _HdAudioCard()),
                const SizedBox(height: 16),
                _entrance(3, _NoiseCleanerCard()),
                const SizedBox(height: 16),
                _entrance(4, _DelayCard()),
                const SizedBox(height: 16),
                _entrance(5, const DiagnosticsCard()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Transport (how the phones link up) ──────────────────────────────────────

/// The hand-pin for the transport, moved off the main Settings page by P2 §1.
///
/// First card rather than last, despite being the newest arrival: it is the
/// only control here that changes what the *primary* screen does, so someone
/// who came looking for "why did it use Bluetooth" should meet it before four
/// cards of audio tuning.
class _TransportCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.podcasts_rounded,
      title: s.settings_section_transport,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: TransportModePicker(),
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
            p.voxMargin != c.voxMargin ||
            p.noiseSuppression != c.noiseSuppression ||
            p.noiseSuppressionEngine != c.noiseSuppressionEngine ||
            p.ridingPreset != c.ridingPreset ||
            p.isLive != c.isLive,
        builder: (context, state) {
          final riding = state.ridingPreset;
          // The slider is a margin above the measured background now, not an
          // absolute level — but it is still drawn as 0–100 %, and a value
          // migrated from the old scale lands on the same percentage it always
          // showed. So this control looks untouched to someone who set it
          // months ago; only what it does changed. See [VoxMargin].
          final marginPercent = (state.voxMargin * 100).clamp(0.0, 100.0).toInt();
          // With no cleaner selected there is nothing for the strength to
          // apply to, so the slider is shown reading OFF and inert rather
          // than left live and lying about having an effect. The stored
          // value is deliberately untouched — it comes back exactly as the
          // user left it the moment they pick a cleaner again.
          final cleanerOff =
              state.noiseSuppressionEngine == NoiseSuppressionEngine.off;
          // Two different reasons a slider stops accepting input, kept apart
          // on purpose. "Cleaner off" means there is nothing for the strength
          // to apply to, and the readout says OFF. The riding preset means
          // something else is choosing the value — the readout must keep
          // showing that value, because it is what the engine is running.
          final locked = cleanerOff || riding;
          final noisePercent = (state.noiseSuppression * 100).round();
          final noiseLabel = cleanerOff || noisePercent == 0
              ? s.noise_filter_off
              : '${noisePercent.localized(context)}%';
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                if (riding)
                  const _RidingOverrideHint()
                else
                  _AppliesHint(
                    live: state.isLive,
                    text: state.isLive
                        ? s.settings_applies_live
                        : s.settings_applies_next_session,
                  ),
                const SizedBox(height: 12),
                _sliderHeader(
                  s.vox_threshold,
                  '${marginPercent.localized(context)}%',
                  active: !riding,
                ),
                SliderTheme(
                  data: _sliderTheme(context),
                  child: Slider(
                    value: state.voxMargin.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    onChanged: riding
                        ? null
                        : (v) => context.read<SettingsCubit>().setVoxMargin(v),
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
                const SizedBox(height: 8),
                // The one thing the percentage cannot say by itself: it is
                // measured against the room, not against silence. Without this
                // line the control reads as the absolute level it used to be,
                // and someone would keep re-tuning it per environment — the
                // exact chore the reframe removes.
                Text(
                  s.vox_margin_hint,
                  style: _hintStyle,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 14),
                _sliderHeader(
                  s.noise_filter,
                  noiseLabel,
                  active: !locked && noisePercent != 0,
                ),
                SliderTheme(
                  data: _sliderTheme(context),
                  child: Slider(
                    value: state.noiseSuppression.clamp(0.0, 1.0),
                    min: 0.0,
                    max: 1.0,
                    // Null disables the Slider outright, which is the point:
                    // see [locked] above.
                    onChanged: locked
                        ? null
                        : (v) =>
                              context.read<SettingsCubit>().setNoiseSuppression(
                                v,
                              ),
                    onChangeEnd: (_) => HapticFeedback.selectionClick(),
                  ),
                ),
                if (cleanerOff)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(s.noise_filter_cleaner_off, style: _hintStyle),
                  )
                else
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

// ── HD audio quality (HD Voice + HD Shared Music) ───────────────────────────

/// Two independent switches over the wire-format negotiation
/// (`AudioCapabilityNegotiator`/`AudioFormatProfile`): HD Voice ranks the
/// 24kHz voice profile above the legacy 16kHz floor, HD Shared Music ranks
/// the 48kHz stereo media profile above "no HD media." Both default on and
/// both only ever raise the ceiling — a peer that doesn't support HD (or a
/// switch turned off) always falls back automatically, never a failure.
///
/// Applies live rather than next-session: flipping either mid-call is the
/// same shape of event as a peer's own support changing mid-call, which
/// negotiation already tolerates — see `SettingsCubit.setHdVoiceEnabled`.
class _HdAudioCard extends StatelessWidget {
  const _HdAudioCard();

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.high_quality_rounded,
      title: s.settings_section_hd_audio,
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) =>
            p.hdVoiceEnabled != c.hdVoiceEnabled ||
            p.hdMusicEnabled != c.hdMusicEnabled,
        builder: (context, state) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              SettingsRow(
                icon: Icons.graphic_eq_rounded,
                label: s.hd_voice_label,
                subtitle: s.hd_voice_desc,
                trailing: Switch(
                  value: state.hdVoiceEnabled,
                  activeThumbColor: AppColors.amber,
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    context.read<SettingsCubit>().setHdVoiceEnabled(v);
                  },
                ),
              ),
              Divider(color: AppColors.border, height: 1),
              SettingsRow(
                icon: Icons.music_note_rounded,
                label: s.hd_music_label,
                subtitle: s.hd_music_desc,
                trailing: Switch(
                  value: state.hdMusicEnabled,
                  activeThumbColor: AppColors.amber,
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    context.read<SettingsCubit>().setHdMusicEnabled(v);
                  },
                ),
              ),
            ],
          ),
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
            p.ridingPreset != c.ridingPreset ||
            p.isLive != c.isLive,
        builder: (context, state) {
          // A platform with no native build path can't run rnnoise
          // regardless of the stored preference — show what's really
          // running, not a selected-but-disabled option that misrepresents
          // the active engine.
          //
          // Only the two rnnoise-backed choices fall back. "Off" runs
          // identically everywhere, so coercing it to spectral here would
          // have a phone without the native library tell a user who asked
          // for no cleaning that the simple cleaner is on — while the engine
          // correctly runs nothing at all.
          final stored = state.noiseSuppressionEngine;
          final needsNative =
              stored == NoiseSuppressionEngine.rnnoise ||
              stored == NoiseSuppressionEngine.both;
          final effectiveEngine = needsNative && !_smartAvailable
              ? NoiseSuppressionEngine.spectral
              : stored;
          // While the preset runs, the selected option is the preset's — shown
          // as the live one, and not re-selectable. Same rule as the platform
          // fallback above: the card reports the running engine, never a
          // stored preference that isn't in effect.
          final riding = state.ridingPreset;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (riding)
                  const _RidingOverrideHint()
                else
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
                  locked: riding,
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
                  locked: riding,
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
                  locked: riding,
                  onTap: () => _select(context, NoiseSuppressionEngine.both),
                ),
                const SizedBox(height: 10),
                // Last, not first: it is the escape hatch for when a cleaner
                // is doing more harm than good, not the choice most people
                // should land on by reading top to bottom.
                _CleanerOption(
                  icon: Icons.block_rounded,
                  title: s.noise_cleaner_off_title,
                  description: s.noise_cleaner_off_desc,
                  downside: s.noise_cleaner_off_downside,
                  selected: effectiveEngine == NoiseSuppressionEngine.off,
                  locked: riding,
                  onTap: () => _select(context, NoiseSuppressionEngine.off),
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

  /// This platform can actually run it — false greys the option out as
  /// unavailable, and it can never appear selected.
  final bool enabled;

  /// Something else is choosing right now (the riding preset). Distinct from
  /// [enabled]: a locked option is still perfectly capable of running, and the
  /// one that *is* running must keep showing as selected. Only the tap goes
  /// away, and only the alternatives dim.
  final bool locked;
  final VoidCallback onTap;

  const _CleanerOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.downside,
    required this.selected,
    this.enabled = true,
    this.locked = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final active = selected && enabled;
    // Dimmed when this phone can't run it, or when the preset is choosing and
    // it isn't the choice. The active one under a lock stays at full contrast:
    // it is what the engine is doing.
    final dim = !enabled || (locked && !active);
    final titleColor = dim
        ? AppColors.textSecondary.withAlpha(110)
        : AppColors.textPrimary;
    final bodyColor = dim
        ? AppColors.textSecondary.withAlpha(110)
        : AppColors.textSecondary;
    return GestureDetector(
      onTap: enabled && !locked ? onTap : null,
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
                      : AppColors.textSecondary.withAlpha(dim ? 80 : 140),
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
                  color: bodyColor.withAlpha(dim ? 110 : 190),
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
                      color: bodyColor.withAlpha(dim ? 110 : 190),
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
        buildWhen: (p, c) =>
            p.targetBufferMs != c.targetBufferMs ||
            p.ridingPreset != c.ridingPreset,
        builder: (context, state) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The jitter buffer never rebuilds mid-call, so unlike the
              // noise cleaner this one always waits for the next session.
              if (state.ridingPreset)
                const _RidingOverrideHint()
              else
                _AppliesHint(
                  live: false,
                  text: s.settings_applies_next_session,
                ),
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
                        color: state.ridingPreset
                            ? AppColors.textSecondary
                            : AppColors.amber,
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
                  onChanged: state.ridingPreset
                      ? null
                      : (v) => context.read<SettingsCubit>().setTargetBufferMs(
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

/// Replaces the "applies instantly / next session" note on any card the
/// riding preset has taken over.
///
/// It stands in for that note rather than sitting alongside it because *when*
/// a change lands stops being the interesting question once no change can be
/// made — and it points at the switch that gives control back, so nobody has
/// to work out why a slider stopped moving.
class _RidingOverrideHint extends StatelessWidget {
  const _RidingOverrideHint();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.two_wheeler_rounded,
          color: AppColors.amber.withAlpha(200),
          size: 12,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            context.getString.settings_riding_overridden,
            style: TextStyle(
              color: AppColors.amber.withAlpha(200),
              fontSize: 10.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

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
