import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../settings/settings_keys.dart';

class LocaleService {
  static final _locale = ValueNotifier<Locale>(const Locale('fa'));
  static late SharedPreferences _prefs;

  static ValueListenable<Locale> get locale => _locale;
  static Locale get currentLocale => _locale.value;

  /// [prefs] is the entrypoint's one process-wide SharedPreferences
  /// resolution — this service runs before (or without) DI, so it receives
  /// the instance instead of resolving its own.
  static void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    _locale.value = Locale(_prefs.getString(SettingsKeys.appLocale) ?? 'fa');
  }

  static Future<void> setLocale(Locale locale) async {
    _locale.value = locale;
    await _prefs.setString(SettingsKeys.appLocale, locale.languageCode);
  }
}
