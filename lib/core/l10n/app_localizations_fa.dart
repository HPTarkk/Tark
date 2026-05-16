// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get app_name => 'واکی تاکی';

  @override
  String get unknown_failure => 'خطای ناشناخته ای رخ داده است';

  @override
  String get audio_recording_general_error_message => 'خطا در شروع ضبط صذا';

  @override
  String get audio_recording_permission_error_message => 'خطا دسترسی به مایک';
}
