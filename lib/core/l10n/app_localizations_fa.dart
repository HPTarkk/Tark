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
  String get app_subtitle => 'بی‌سیم شبکه محلی';

  @override
  String get live => 'آنلاین';

  @override
  String get offline => 'آفلاین';

  @override
  String get edit_name => 'ویرایش';

  @override
  String get connecting => 'در حال اتصال...';

  @override
  String get monitoring => 'در حال پایش...';

  @override
  String get initializing => 'در حال راه‌اندازی';

  @override
  String get tx_label => 'TX';

  @override
  String get rx_label => 'RX';

  @override
  String get channel_members => 'اعضای کانال';

  @override
  String get no_users_on_network => 'هیچ کاربری در این شبکه نیست';

  @override
  String get vox_sensitivity => 'حساسیت VOX';

  @override
  String get vox_threshold => 'آستانه';

  @override
  String get voice_loud => 'صدای بلند';

  @override
  String get voice_quiet => 'صدای آرام';

  @override
  String get level_label => 'سطح';

  @override
  String get level_active => 'فعال';

  @override
  String get level_silent => 'ساکت';

  @override
  String get user_idle => 'آماده';

  @override
  String get set_name_title => 'نام خود را تنظیم کنید';

  @override
  String get name_hint => 'نام خود را وارد کنید';

  @override
  String get cancel => 'لغو';

  @override
  String get save => 'ذخیره';

  @override
  String get mic_permission_denied =>
      'دسترسی به میکروفن رد شد. لطفاً در تنظیمات مجوز دسترسی را فعال کنید.';

  @override
  String get join_channel => 'ورود به کانال';

  @override
  String get leave_channel => 'خروج از کانال';

  @override
  String get no_network => 'شبکه‌ای یافت نشد';

  @override
  String get leave_channel_confirm_title => 'خروج از کانال؟';

  @override
  String get leave_channel_confirm_message =>
      'ارتباط شما با سایر اعضای کانال قطع خواهد شد.';

  @override
  String get leave => 'خروج';
}
