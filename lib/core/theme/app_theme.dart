import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import 'app_colors.dart';
import 'theme_service.dart';

/// The one `ThemeData` both entrypoints build.
///
/// The app and the web guest used to each assemble their own, and the guest's
/// copy had drifted: it had no colour scheme, so anything reading
/// `colorScheme.primary` came out Material's default purple instead of amber.
/// Built fresh on every call because [AppColors] follows the current
/// [ThemeService] mode.
ThemeData buildAppTheme() => ThemeData(
  fontFamily: 'Vazirmatn',
  brightness: ThemeService.isLight ? Brightness.light : Brightness.dark,
  scaffoldBackgroundColor: AppColors.background,
  colorScheme: ThemeService.isLight
      ? ColorScheme.light(
          primary: AppColors.amber,
          secondary: AppColors.green,
          surface: AppColors.surface,
          error: AppColors.red,
        )
      : ColorScheme.dark(
          primary: AppColors.amber,
          secondary: AppColors.green,
          surface: AppColors.surface,
          error: AppColors.red,
        ),
  useMaterial3: true,
  // M3 snackbars default to inverseSurface/onInverseSurface, which clashes
  // with our card-colored backgrounds; pin both sides here so every SnackBar
  // is card + readable text without per-call overrides.
  snackBarTheme: SnackBarThemeData(
    backgroundColor: AppColors.card,
    contentTextStyle: TextStyle(
      fontFamily: 'Vazirmatn',
      color: AppColors.textPrimary,
      fontSize: 14,
    ),
    actionTextColor: AppColors.amber,
  ),
  pageTransitionsTheme: AppPageTransitionsBuilder.theme,
);
