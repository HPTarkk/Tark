import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../../core/settings/settings_repository_impl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../audio/api/audio_api.dart';

/// One-time card nudging the rider to let the app run in the background — the
/// screen-off keep-alive service can hold the CPU/Wi-Fi awake, but an OS
/// battery manager (Doze, and especially MIUI/Xiaomi) will still freeze or kill
/// the app unless the user whitelists it.
///
/// Shows only on Android, only while the app is NOT battery-optimization
/// exempt, and never again once dismissed (persisted flag). On MIUI it also
/// offers the Autostart shortcut, which is the setting that actually stops MIUI
/// from killing background apps. Re-checks on resume so it disappears the
/// moment the user grants the exemption.
class BackgroundPermissionBanner extends StatefulWidget {
  const BackgroundPermissionBanner({super.key});

  @override
  State<BackgroundPermissionBanner> createState() =>
      _BackgroundPermissionBannerState();
}

class _BackgroundPermissionBannerState extends State<BackgroundPermissionBanner>
    with WidgetsBindingObserver {
  final SettingsRepository _settingsRepository = SettingsRepositoryImpl();
  bool _show = false;
  bool _isMiui = false;

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
    // The user returns from the system battery/Autostart screen — re-check so
    // the banner hides itself once the exemption is granted.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (!Platform.isAndroid) {
      if (mounted && _show) setState(() => _show = false);
      return;
    }
    if (await _settingsRepository.getBgPermBannerDismissed()) {
      if (mounted && _show) setState(() => _show = false);
      return;
    }
    final ignoring = await SessionKeepAlive.isIgnoringBatteryOptimizations();
    final miui = await SessionKeepAlive.isMiui();
    if (!mounted) return;
    setState(() {
      _show = !ignoring;
      _isMiui = miui;
    });
  }

  Future<void> _dismiss() async {
    setState(() => _show = false);
    await _settingsRepository.setBgPermBannerDismissed(true);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      child: !_show
          ? const SizedBox(width: double.infinity)
          : _buildCard(context),
    );
  }

  Widget _buildCard(BuildContext context) {
    final s = context.getString;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.amber.withAlpha(18),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.battery_saver_rounded,
                color: AppColors.amber,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.background_title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            s.background_desc,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ActionChip(
                label: s.background_allow,
                filled: true,
                onTap: () =>
                    SessionKeepAlive.requestIgnoreBatteryOptimizations(),
              ),
              if (_isMiui)
                _ActionChip(
                  label: s.background_autostart,
                  filled: false,
                  onTap: () => SessionKeepAlive.openAutoStartSettings(),
                ),
              _ActionChip(
                label: s.background_dismiss,
                filled: false,
                muted: true,
                onTap: _dismiss,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final bool filled;
  final bool muted;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.filled,
    required this.onTap,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppColors.textSecondary : AppColors.amber;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: filled ? AppColors.amber.withAlpha(28) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(filled ? 130 : 90)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }
}
