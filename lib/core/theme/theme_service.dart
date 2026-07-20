import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/settings_keys.dart';

enum AppThemeMode { dark, light }

class ThemeService {
  static final _mode = ValueNotifier<AppThemeMode>(AppThemeMode.dark);
  static late SharedPreferences _prefs;

  static ValueListenable<AppThemeMode> get mode => _mode;
  static AppThemeMode get currentMode => _mode.value;
  static bool get isLight => _mode.value == AppThemeMode.light;

  /// [prefs] is the entrypoint's one process-wide SharedPreferences
  /// resolution — this service runs before (or without) DI, so it receives
  /// the instance instead of resolving its own.
  static void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    final stored = _prefs.getString(SettingsKeys.appTheme);
    _mode.value = stored == 'light' ? AppThemeMode.light : AppThemeMode.dark;
  }

  static Future<void> setMode(AppThemeMode mode) async {
    _mode.value = mode;
    await _prefs.setString(SettingsKeys.appTheme, mode.name);
  }
}
