import 'package:flutter/material.dart';

import '../locale/locale_service.dart';
import '../theme/app_colors.dart';

/// Language selection toggle (فارسی / English).
///
/// Always rendered LTR regardless of app locale so the layout is predictable.
class LanguageToggle extends StatelessWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleService.locale,
      builder: (_, currentLocale, _) => Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _LanguageChip(
              label: 'فارسی',
              locale: const Locale('fa'),
              isSelected: currentLocale.languageCode == 'fa',
            ),
            const SizedBox(width: 12),
            _LanguageChip(
              label: 'English',
              locale: const Locale('en'),
              isSelected: currentLocale.languageCode == 'en',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Language chip ─────────────────────────────────────────────────────────────

class _LanguageChip extends StatelessWidget {
  final String label;
  final Locale locale;
  final bool isSelected;

  const _LanguageChip({
    required this.label,
    required this.locale,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => LocaleService.setLocale(locale),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.amber.withAlpha(25) : AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.amber : AppColors.border,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? AppColors.amber : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
