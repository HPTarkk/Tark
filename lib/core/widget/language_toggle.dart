import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../locale/locale_service.dart';
import '../theme/app_colors.dart';
import 'theme_reveal_transition.dart';

/// Language selector (فارسی / English) — a segmented slider whose glowing
/// amber thumb glides to the active language, while the existing full-screen
/// circular reveal wipes the new locale in from the tap point.
///
/// Always rendered LTR regardless of app locale so the layout is predictable.
class LanguageToggle extends StatelessWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return ValueListenableBuilder<Locale>(
      valueListenable: LocaleService.locale,
      builder: (context, currentLocale, _) {
        final isFa = currentLocale.languageCode == 'fa';
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            height: 58,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.border),
            ),
            child: Stack(
              children: [
                AnimatedAlign(
                  alignment: isFa
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  duration: reduced
                      ? Duration.zero
                      : const Duration(milliseconds: 420),
                  curve: Curves.easeOutQuart,
                  child: FractionallySizedBox(
                    widthFactor: 0.5,
                    heightFactor: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: AppColors.amber.withAlpha(150),
                          width: 1.2,
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.amber.withAlpha(40),
                            AppColors.amber.withAlpha(14),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.amber.withAlpha(45),
                            blurRadius: 14,
                            spreadRadius: -2,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _LanguageSegment(
                      label: 'فارسی',
                      code: 'FA',
                      locale: const Locale('fa'),
                      isSelected: isFa,
                    ),
                    _LanguageSegment(
                      label: 'English',
                      code: 'EN',
                      locale: const Locale('en'),
                      isSelected: !isFa,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Language segment ─────────────────────────────────────────────────────────

class _LanguageSegment extends StatelessWidget {
  final String label;
  final String code;
  final Locale locale;
  final bool isSelected;

  const _LanguageSegment({
    required this.label,
    required this.code,
    required this.locale,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          if (isSelected) return;
          HapticFeedback.selectionClick();
          AppRevealController.reveal(
            context: context,
            origin: details.globalPosition,
            applyChange: () => LocaleService.setLocale(locale),
          );
        },
        child: Center(
          child: AnimatedScale(
            scale: isSelected ? 1.0 : 0.92,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: TextStyle(
                    color: isSelected
                        ? AppColors.amber
                        : AppColors.textSecondary,
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                    fontFamily: 'Vazirmatn',
                  ),
                  child: Text(label),
                ),
                const SizedBox(height: 2),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: TextStyle(
                    color:
                        (isSelected ? AppColors.amber : AppColors.textSecondary)
                            .withAlpha(isSelected ? 200 : 130),
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3,
                  ),
                  child: Text(code),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
