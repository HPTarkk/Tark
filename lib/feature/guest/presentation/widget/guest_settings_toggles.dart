import 'package:flutter/material.dart';

import '../../../../core/locale/locale_service.dart';
import '../../../../core/sfx/sfx_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/theme_service.dart';

/// Language + theme + sound-feedback toggle chips for the web guest app.
/// Shared by the QR phases (floating, top corner) and the connected console
/// header.
class GuestSettingsToggles extends StatelessWidget {
  const GuestSettingsToggles({super.key});

  @override
  Widget build(BuildContext context) {
    // Read the ACTIVE locale from Localizations (not LocaleService directly):
    // this registers an inherited-widget dependency so the chip rebuilds when
    // the language flips — reading the static value froze the label until a
    // page refresh.
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToggleChip(
          label: isFa ? 'EN' : 'فا',
          onTap: () => LocaleService.setLocale(Locale(isFa ? 'en' : 'fa')),
        ),
        const SizedBox(width: 8),
        _ToggleChip(
          icon: ThemeService.isLight
              ? Icons.dark_mode_rounded
              : Icons.light_mode_rounded,
          onTap: () => ThemeService.setMode(
            ThemeService.isLight ? AppThemeMode.dark : AppThemeMode.light,
          ),
        ),
        const SizedBox(width: 8),
        ValueListenableBuilder<bool>(
          valueListenable: Sfx.enabled,
          builder: (context, enabled, _) => _ToggleChip(
            icon: enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            onTap: () => Sfx.setEnabled(!enabled),
          ),
        ),
      ],
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  const _ToggleChip({this.label, this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: icon != null
            ? Icon(icon, color: AppColors.amber, size: 17)
            : Text(
                label!,
                style: TextStyle(
                  color: AppColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }
}
