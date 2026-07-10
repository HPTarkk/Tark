import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/settings_keys.dart';

class LocaleService {
  static final _locale = ValueNotifier<Locale>(const Locale('fa'));

  static ValueListenable<Locale> get locale => _locale;
  static Locale get currentLocale => _locale.value;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(SettingsKeys.appLocale) ?? 'fa';
    _locale.value = Locale(code);
  }

  static Future<void> setLocale(Locale locale) async {
    _locale.value = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SettingsKeys.appLocale, locale.languageCode);
  }
}
