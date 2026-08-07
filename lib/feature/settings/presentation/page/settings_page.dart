import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/analytics/analytics.dart';
import '../../../../core/analytics/analytics_event.dart';
import '../../../../core/home_widget/home_widget_service.dart';
import '../../../../core/l10n/extension.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/app_avatar.dart';
import '../../../../core/widget/language_toggle.dart';
import '../../../../core/widget/theme_toggle.dart';
import '../../../walkie/api/walkie_api.dart';
import '../manager/settings_cubit.dart';
import '../widget/diagnostics_card.dart';
import '../widget/settings_category_card.dart';
import '../widget/settings_row.dart';
import '../widget/transport_mode_picker.dart';

/// Categorized Settings/Profile page — Profile, Voice & Audio, Connection,
/// Sound & Alerts, Appearance, and Startup, each its own
/// [SettingsCategoryCard] instead of one long flat list.
///
/// [buildPage] accepts an optional already-running [WalkieTalkieCubit]
/// (passed via go_router's `extra` by whoever navigates here) so changes
/// apply live to an active channel — see [SettingsCubit].
class SettingsPage extends StatefulWidget {
  const SettingsPage._();

  static Widget buildPage({Object? liveSession}) => BlocProvider<SettingsCubit>(
    create: (_) => SettingsCubit(
      liveSession: liveSession as WalkieTalkieCubit?,
      repository: GetIt.instance<SettingsRepository>(),
      analytics: GetIt.instance<Analytics>(),
    ),
    child: const SettingsPage._(),
  );

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with TickerProviderStateMixin {
  // Staggered entrance, same pattern as landing/walkie pages: [profile,
  // connection, sound, appearance, startup, privacy, diagnostics, advanced-nav]
  late AnimationController _entranceController;
  late List<Animation<double>> _sections;

  static const _sectionCount = 8;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
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
                _entrance(0, _ProfileCard()),
                const SizedBox(height: 16),
                _entrance(1, _ConnectionCard()),
                const SizedBox(height: 16),
                _entrance(2, _SoundCard()),
                const SizedBox(height: 16),
                _entrance(3, _AppearanceCard()),
                const SizedBox(height: 16),
                _entrance(4, _StartupCard()),
                const SizedBox(height: 16),
                _entrance(5, _PrivacyCard()),
                const SizedBox(height: 16),
                _entrance(6, const DiagnosticsCard()),
                const SizedBox(height: 16),
                _entrance(7, _AdvancedNavCard()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Profile ──────────────────────────────────────────────────────────────────

class _ProfileCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return BlocBuilder<SettingsCubit, SettingsState>(
      buildWhen: (p, c) => p.myName != c.myName,
      builder: (context, state) => SettingsCategoryCard(
        icon: Icons.person_rounded,
        title: s.settings_section_identity,
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
                      Icon(
                        Icons.edit_rounded,
                        color: AppColors.amber,
                        size: 14,
                      ),
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
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: s.name_hint,
            hintStyle: TextStyle(color: AppColors.textSecondary.withAlpha(160)),
            counterStyle: TextStyle(
              color: AppColors.textSecondary.withAlpha(120),
            ),
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
            child: Text(
              s.cancel,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              cubit.setMyName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: Text(
              s.save,
              style: TextStyle(
                color: AppColors.amber,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Advanced (navigation to the sub-page) ───────────────────────────────────

/// Entry point to [AdvancedSettingsPage] — the technical knobs (noise-cleaner
/// engine, playback delay) live there so this page stays approachable. The
/// live-session cubit is forwarded so those knobs keep applying live.
class _AdvancedNavCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.amber.withAlpha(10),
            blurRadius: 22,
            spreadRadius: -6,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SettingsRow(
        icon: Icons.tune_rounded,
        label: s.settings_advanced_row,
        subtitle: s.settings_advanced_row_desc,
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: AppColors.textSecondary,
        ),
        onTap: () {
          HapticFeedback.selectionClick();
          context.pushNamed(
            AppRoutes.advancedSettingsName,
            extra: context.read<SettingsCubit>().liveSession,
          );
        },
      ),
    );
  }
}

// ── Connection ───────────────────────────────────────────────────────────────

class _ConnectionCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.podcasts_rounded,
      title: s.settings_section_connection,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          children: [
            const TransportModePicker(),
            const SizedBox(height: 4),
            Divider(color: AppColors.border, height: 1),
            BlocBuilder<SettingsCubit, SettingsState>(
              buildWhen: (p, c) =>
                  p.autoReconnectEnabled != c.autoReconnectEnabled,
              builder: (context, state) => SettingsRow(
                icon: Icons.sync_rounded,
                label: s.settings_auto_reconnect,
                subtitle: s.settings_auto_reconnect_desc,
                trailing: Switch(
                  value: state.autoReconnectEnabled,
                  activeThumbColor: AppColors.amber,
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    context.read<SettingsCubit>().setAutoReconnectEnabled(v);
                  },
                ),
              ),
            ),
            Divider(color: AppColors.border, height: 1),
            SettingsRow(
              icon: Icons.wifi_tethering_rounded,
              label: s.settings_wifi_hotspot_row,
              subtitle: s.settings_wifi_hotspot_row_desc,
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
              onTap: () => context.pushNamed(
                AppRoutes.wifiHotspotName,
                queryParameters: const {'mode': 'wifi'},
              ),
            ),
            Divider(color: AppColors.border, height: 1),
            SettingsRow(
              icon: Icons.shield_rounded,
              label: s.settings_permissions_row,
              subtitle: s.settings_permissions_row_desc,
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
              onTap: () => context.pushNamed(AppRoutes.permissionsName),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sound & alerts ───────────────────────────────────────────────────────────

class _SoundCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.volume_up_rounded,
      title: s.settings_section_sound,
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
    );
  }
}

// ── Appearance ───────────────────────────────────────────────────────────────

class _AppearanceCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.palette_rounded,
      title: s.settings_section_appearance,
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
    );
  }
}

/// One-tap "add the home-screen widget", shown only where the launcher can
/// actually do it.
///
/// This is the app's only pointer to the widget existing at all — a widget
/// nobody knows to look for in the launcher's picker may as well not ship.
/// It hides itself rather than explaining how to long-press the home screen:
/// the wording differs per launcher and per iOS version, so instructions we
/// can't verify would be worse than nothing.
class _AddWidgetRow extends StatefulWidget {
  const _AddWidgetRow();

  @override
  State<_AddWidgetRow> createState() => _AddWidgetRowState();
}

class _AddWidgetRowState extends State<_AddWidgetRow> {
  bool _supported = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final supported = await GetIt.instance<HomeWidgetService>().canPin();
    if (mounted) setState(() => _supported = supported);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final s = context.getString;
    return Column(
      children: [
        Divider(color: AppColors.border, height: 1),
        SettingsRow(
          icon: Icons.widgets_rounded,
          label: s.settings_add_widget,
          subtitle: s.settings_widget_hint,
          trailing: Icon(
            Icons.add_rounded,
            color: AppColors.amber,
          ),
          onTap: () {
            HapticFeedback.selectionClick();
            context.read<SettingsCubit>().recordFeatureUsed(
              AppFeature.homeWidget,
            );
            // The launcher takes it from here with its own confirmation, so
            // there's no result worth waiting for.
            GetIt.instance<HomeWidgetService>().requestPin();
          },
        ),
      ],
    );
  }
}

// ── Privacy ──────────────────────────────────────────────────────────────────

/// The one place the app admits it phones home at all.
///
/// Tark's whole pitch is that conversations never leave the local link, and
/// that stays true — analytics carries no names, no addresses and no audio,
/// only bucketed counters about which transports connect and where pairing
/// fails (see lib/core/analytics/analytics_event.dart). But a user who
/// believes "no server" deserves to find the switch without hunting, and to
/// read what it does in plain language before deciding.
class _PrivacyCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.privacy_tip_rounded,
      title: s.settings_section_privacy,
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) => p.analyticsEnabled != c.analyticsEnabled,
        builder: (context, state) => SettingsRow(
          icon: Icons.insights_rounded,
          label: s.settings_analytics,
          subtitle: s.settings_analytics_desc,
          trailing: Switch(
            value: state.analyticsEnabled,
            activeThumbColor: AppColors.amber,
            onChanged: (v) {
              HapticFeedback.selectionClick();
              context.read<SettingsCubit>().setAnalyticsEnabled(v);
            },
          ),
        ),
      ),
    );
  }
}

// ── Startup ──────────────────────────────────────────────────────────────────

class _StartupCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return SettingsCategoryCard(
      icon: Icons.rocket_launch_rounded,
      title: s.settings_section_startup,
      // The "quick access" toggle used to sit here, controlling whether cold
      // start skipped Landing for the last-used mode. That behaviour is gone —
      // the home-screen widget covers the same ground on request rather than
      // on every launch (see QuickAccess) — so the switch went with it.
      child: BlocBuilder<SettingsCubit, SettingsState>(
        buildWhen: (p, c) => p.skipSplash != c.skipSplash,
        builder: (context, state) => Column(
          children: [
            SettingsRow(
              icon: Icons.flash_on_rounded,
              label: s.settings_skip_splash,
              subtitle: s.settings_skip_splash_desc,
              trailing: Switch(
                value: state.skipSplash,
                activeThumbColor: AppColors.amber,
                onChanged: (v) {
                  HapticFeedback.selectionClick();
                  context.read<SettingsCubit>().setSkipSplash(v);
                },
              ),
            ),
            const _AddWidgetRow(),
            Divider(color: AppColors.border, height: 1),
            SettingsRow(
              icon: Icons.replay_rounded,
              label: s.settings_replay_intro,
              subtitle: s.settings_replay_intro_desc,
              trailing: Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
              onTap: () {
                context.read<SettingsCubit>().recordFeatureUsed(
                  AppFeature.replayIntro,
                );
                context.pushNamed(
                  AppRoutes.onboardingName,
                  queryParameters: const {'replay': 'true'},
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
