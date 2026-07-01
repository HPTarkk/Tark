import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme_service.dart';

/// One complete color set. Two instances exist — [dark] and [light] — and
/// [AppColors] resolves against whichever one [ThemeService] says is active.
class AppPalette {
  final Color background;
  final Color surface;
  final Color card;
  final Color border;
  final Color amber;
  final Color amberDim;
  final Color red;
  final Color green;
  final Color textPrimary;
  final Color textSecondary;

  const AppPalette({
    required this.background,
    required this.surface,
    required this.card,
    required this.border,
    required this.amber,
    required this.amberDim,
    required this.red,
    required this.green,
    required this.textPrimary,
    required this.textSecondary,
  });

  /// Original "night radio" look — deep navy with amber glow.
  static const dark = AppPalette(
    background: Color(0xFF080B14),
    surface: Color(0xFF0F1320),
    card: Color(0xFF141929),
    border: Color(0xFF1E2845),
    amber: Color(0xFFFFB74D),
    amberDim: Color(0xFFFF8F00),
    red: Color(0xFFEF5350),
    green: Color(0xFF4CAF50),
    textPrimary: Color(0xFFECEFF1),
    textSecondary: Color(0xFF78909C),
  );

  /// "Field radio" light look — warm paper and brass. Amber is darkened so
  /// it keeps contrast on cream backgrounds while glows/tints (which are
  /// applied via withAlpha) stay warm.
  static const light = AppPalette(
    background: Color(0xFFF6F1E7),
    surface: Color(0xFFEFE8D8),
    card: Color(0xFFFFFDF7),
    border: Color(0xFFE0D5BD),
    amber: Color(0xFFB26B00),
    amberDim: Color(0xFF8A5200),
    red: Color(0xFFC62828),
    green: Color(0xFF2E7D32),
    textPrimary: Color(0xFF2A2418),
    textSecondary: Color(0xFF857A64),
  );
}

/// Theme-aware color access. These are getters (not consts) so every widget
/// rebuild picks up the active palette; the whole tree is rebuilt from the
/// root when [ThemeService] changes, same as locale switches.
abstract final class AppColors {
  static AppPalette get palette =>
      ThemeService.isLight ? AppPalette.light : AppPalette.dark;

  static Color get background => palette.background;
  static Color get surface => palette.surface;
  static Color get card => palette.card;
  static Color get border => palette.border;
  static Color get amber => palette.amber;
  static Color get amberDim => palette.amberDim;
  static Color get red => palette.red;
  static Color get green => palette.green;
  static Color get textPrimary => palette.textPrimary;
  static Color get textSecondary => palette.textSecondary;

  /// Status/navigation bar chrome matching the active palette.
  static SystemUiOverlayStyle get systemOverlayStyle {
    final icons = ThemeService.isLight ? Brightness.dark : Brightness.light;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      systemNavigationBarColor: background,
      systemNavigationBarIconBrightness: icons,
    );
  }
}
