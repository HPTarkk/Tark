import 'package:flutter/material.dart';

import '../l10n/extension.dart';
import '../theme/app_colors.dart';
import '../theme/theme_service.dart';

/// Dark / light theme toggle, styled to match [LanguageToggle].
///
/// Always rendered LTR so the dark chip stays on the left in both locales.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeService.mode,
      builder: (_, currentMode, _) => Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ThemeChip(
              label: s.theme_dark,
              icon: Icons.dark_mode_rounded,
              mode: AppThemeMode.dark,
              isSelected: currentMode == AppThemeMode.dark,
            ),
            const SizedBox(width: 12),
            _ThemeChip(
              label: s.theme_light,
              icon: Icons.light_mode_rounded,
              mode: AppThemeMode.light,
              isSelected: currentMode == AppThemeMode.light,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Theme chip ────────────────────────────────────────────────────────────────

class _ThemeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final AppThemeMode mode;
  final bool isSelected;

  const _ThemeChip({
    required this.label,
    required this.icon,
    required this.mode,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => ThemeService.setMode(mode),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.amber.withAlpha(25) : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.amber : AppColors.border,
            width: 1.5,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.amber.withAlpha(30),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedRotation(
              turns: isSelected ? 0.0 : -0.15,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutBack,
              child: Icon(
                icon,
                size: 14,
                color: isSelected ? AppColors.amber : AppColors.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? AppColors.amber : AppColors.textSecondary,
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
