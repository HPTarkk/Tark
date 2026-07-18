import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/l10n/extension.dart';
import '../../../../core/locale/locale_service.dart';
import '../../../../core/theme/theme_service.dart';
import '../manager/onboarding_cubit.dart';
import 'hud.dart';
import 'onboarding_palette.dart';

/// Beat 0 — tune the radio to your taste. Language applies live; the Day/Night
/// plates don't flip the app theme (that would re-key the world) but instead
/// drive the [HorizonScene]'s environmental sunrise/sunset, recording the
/// choice on the cubit for launch. Rendered entirely with the HUD kit.
class TuneStep extends StatelessWidget {
  final Animation<double> reveal;

  const TuneStep({super.key, required this.reveal});

  @override
  Widget build(BuildContext context) {
    final s = context.getString;
    final cubit = context.read<OnboardingCubit>();
    return StaggeredItem(
      reveal: reveal,
      index: 0,
      count: 1,
      child: HudPanel(
        header: s.onboarding_tune_title,
        status: '01·05',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.onboarding_tune_sub,
              style: const TextStyle(
                color: Onb.textDim,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            _Label(s.onboarding_language_label),
            const SizedBox(height: 8),
            ValueListenableBuilder<Locale>(
              valueListenable: LocaleService.locale,
              builder: (_, locale, _) {
                final isFa = locale.languageCode == 'fa';
                return Row(
                  children: [
                    Expanded(
                      child: HudOption(
                        compact: true,
                        selected: isFa,
                        label: 'فارسی',
                        onTap: () => LocaleService.setLocale(const Locale('fa')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: HudOption(
                        compact: true,
                        selected: !isFa,
                        label: 'English',
                        onTap: () => LocaleService.setLocale(const Locale('en')),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            _Label(s.onboarding_theme_label),
            const SizedBox(height: 8),
            BlocBuilder<OnboardingCubit, OnboardingState>(
              buildWhen: (p, c) => p.themePref != c.themePref,
              builder: (_, state) => HudSunMoonTiles(
                night: state.themePref == AppThemeMode.dark,
                onSelect: (night) => cubit.selectTheme(
                  night ? AppThemeMode.dark : AppThemeMode.light,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) {
    final isFa = Localizations.localeOf(context).languageCode == 'fa';
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: Onb.amber.withAlpha(180),
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: isFa ? 0.4 : 2,
      ),
    );
  }
}
