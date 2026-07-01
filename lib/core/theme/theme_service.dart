import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { dark, light }

class ThemeService {
  static final _mode = ValueNotifier<AppThemeMode>(AppThemeMode.dark);

  static ValueListenable<AppThemeMode> get mode => _mode;
  static AppThemeMode get currentMode => _mode.value;
  static bool get isLight => _mode.value == AppThemeMode.light;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('app_theme');
    _mode.value =
        stored == 'light' ? AppThemeMode.light : AppThemeMode.dark;
  }

  static Future<void> setMode(AppThemeMode mode) async {
    _mode.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_theme', mode.name);
  }
}
