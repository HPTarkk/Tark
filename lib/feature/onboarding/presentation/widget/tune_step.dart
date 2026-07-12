import 'package:flutter/material.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widget/language_toggle.dart';
import '../../../../core/widget/theme_toggle.dart';
import 'onboarding_emblem.dart';

/// Beat 0 — tune the radio to your taste: language and theme, applied live
/// through the same [LanguageToggle]/[ThemeToggle] controls the user will
/// meet again in Settings. This runs before any copy-heavy beat so nobody
/// reads a wall of Persian (or English) they didn't choose.
class TuneStep extends StatelessWidget {
  final Animation<double> reveal;

  const TuneStep({super.key, required this.reveal});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StaggeredItem(
          reveal: reveal,
          index: 0,
          count: 6,
          child: Text(
            s.onboarding_tune_title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 10),
        StaggeredItem(
          reveal: reveal,
          index: 1,
          count: 6,
          child: Text(
            s.onboarding_tune_sub,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 24),
        StaggeredItem(
          reveal: reveal,
          index: 2,
          count: 6,
          child: _SectionLabel(text: s.onboarding_language_label),
        ),
        const SizedBox(height: 8),
        StaggeredItem(
          reveal: reveal,
          index: 3,
          count: 6,
          child: const LanguageToggle(),
        ),
        const SizedBox(height: 20),
        StaggeredItem(
          reveal: reveal,
          index: 4,
          count: 6,
          child: _SectionLabel(text: s.onboarding_theme_label),
        ),
        const SizedBox(height: 8),
        StaggeredItem(
          reveal: reveal,
          index: 5,
          count: 6,
          child: const ThemeToggle(),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Text(
      text,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        // Persian is a joined script — tracking stays latin-only.
        letterSpacing: isFa ? 0.4 : 2,
      ),
    );
  }
}
