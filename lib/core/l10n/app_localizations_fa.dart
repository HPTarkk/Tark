// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get app_name => 'تَرک';

  @override
  String get app_subtitle => 'واکی تاکی شبکه داخلی';

  @override
  String get live => 'زنده';

  @override
  String get offline => 'آفلاین';

  @override
  String get edit_name => 'ویرایش';

  @override
  String get connecting => 'در حال اتصال...';

  @override
  String get monitoring => 'در حال پایش';

  @override
  String get initializing => 'در حال راه‌اندازی';

  @override
  String get tx_label => 'ارسال (TX)';

  @override
  String get rx_label => 'دریافت (RX)';

  @override
  String get music_cast => 'پخش موزیک';

  @override
  String get music_cast_hint =>
      'پخش موزیک و صداهای برنامه‌های این گوشی برای همه افراد در کانال.';

  @override
  String get music_cast_start => 'شروع پخش';

  @override
  String get music_cast_starting => 'در حال شروع...';

  @override
  String get music_cast_stop => 'توقف';

  @override
  String get music_cast_on_air => 'در حال پخش';

  @override
  String get music_cast_mix => 'سطح ترکیب صدا';

  @override
  String get music_cast_silent =>
      'چیزی در حال پخش نیست — یک آهنگ در برنامه موزیک خود اجرا کنید';

  @override
  String get channel_members => 'اعضای کانال';

  @override
  String get no_users_on_network => 'کاربر دیگری در این شبکه وجود ندارد';

  @override
  String get vox_sensitivity => 'حساسیت VOX';

  @override
  String get vox_threshold => 'آستانه صدا';

  @override
  String get voice_loud => 'بلند';

  @override
  String get voice_quiet => 'آرام';

  @override
  String get level_label => 'سطح';

  @override
  String get level_active => 'فعال';

  @override
  String get level_silent => 'بی‌صدا';

  @override
  String get user_idle => 'بیکار';

  @override
  String get set_name_title => 'نام خود را وارد کنید';

  @override
  String get name_hint => 'نام خود را بنویسید';

  @override
  String get cancel => 'لغو';

  @override
  String get save => 'ذخیره';

  @override
  String get mic_permission_denied =>
      'دسترسی به میکروفون رد شد. لطفاً آن را در تنظیمات فعال کنید.';

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
      'اتصال شما با سایر اعضای این کانال قطع خواهد شد.';

  @override
  String get leave => 'خروج';

  @override
  String get transport_wifi => 'وای‌فای';

  @override
  String get transport_bluetooth => 'بلوتوث';

  @override
  String get transport_guest => 'مهمان';

  @override
  String get guest_invite_title => 'دعوت از مهمان';

  @override
  String get guest_step_scan =>
      'مهمان این کد را با دوربین گوشی خود اسکن می‌کند — صفحه ورود در مرورگر او باز می‌شود (هر دو دستگاه باید روی یک وای‌فای باشند).';

  @override
  String get guest_step_answer =>
      'سپس یک کد پاسخ روی صفحه او نشان داده می‌شود — آن را با دکمه زیر اسکن کنید.';

  @override
  String get guest_scan_answer => 'اسکن کد پاسخ';

  @override
  String get guest_link_failed =>
      'اتصال برقرار نشد. یک دعوت‌نامه جدید بسازید و دوباره تلاش کنید.';

  @override
  String get guest_web_scan_title => 'اسکن برای ورود';

  @override
  String get guest_web_scan_text =>
      'این صفحه را با اسکن کردن کد QR دعوت در گوشی میزبان باز کنید — خود لینک حاوی اطلاعات اتصال است.';

  @override
  String get guest_web_failed_title => 'خطا در اتصال';

  @override
  String get guest_web_failed_text =>
      'اتصال برقرار نشد. از میزبان بخواهید یک دعوت‌نامه جدید بسازید و دوباره آن را اسکن کنید (هر دو دستگاه باید به یک وای‌فای متصل باشند).';

  @override
  String get guest_web_reply_chip => 'مرحله ۲ — کد پاسخ';

  @override
  String get guest_web_reply_title => 'این کد را به گوشی میزبان نشان دهید';

  @override
  String get guest_web_reply_hint =>
      'در گوشی میزبان: روی \"اسکن کد پاسخ\" بزنید و دوربین را به این سمت بگیرید.';

  @override
  String get guest_web_connected => 'متصل شد!';

  @override
  String get guest_web_enable_audio =>
      'برای فعال کردن میکروفون و بلندگوی خود، روی دکمه زیر بزنید.';

  @override
  String get guest_web_start_audio => 'شروع صدا';

  @override
  String get guest_web_mute => 'بی‌صدا';

  @override
  String get guest_web_unmute => 'صدادار';

  @override
  String get guest_web_talking => 'در حال صحبت...';

  @override
  String get guest_web_on_air => 'صدای شما در حال پخش است';

  @override
  String get guest_web_standby => 'آماده‌به‌کار';

  @override
  String get guest_web_link_lost => 'قطع اتصال';

  @override
  String get guest_web_link_lost_text => 'اتصال قطع شد — در حال انتظار...';

  @override
  String get guest_web_left_title => 'شما کانال را ترک کردید';

  @override
  String get guest_web_left_text =>
      'ارتباط شما قطع شد. برای ورود مجدد، از میزبان یک دعوت‌نامه جدید بگیرید و دوباره اسکن کنید.';

  @override
  String get bt_start_session => 'شروع نشست';

  @override
  String get bt_role_host_desc =>
      'پخش سیگنال نشست تا دستگاه‌های دیگر بتوانند آن را پیدا کرده و متصل شوند';

  @override
  String get bt_find_nearby => 'جستجوی اطراف';

  @override
  String get bt_role_join_desc => 'اسکن محیط و اتصال به یک نشست در نزدیک';

  @override
  String get bt_visible_as => 'قابل رویت با نام';

  @override
  String get bt_last_session => 'آخرین نشست';

  @override
  String get bt_reconnect => 'اتصال مجدد';

  @override
  String get bt_link_reconnecting =>
      'اتصال بلوتوث قطع شد — در حال اتصال مجدد...';

  @override
  String get bt_waiting_for_peer => 'در انتظار اتصال طرف مقابل...';

  @override
  String get bt_scanning => 'در حال اسکن...';

  @override
  String get bt_no_devices_found => 'دستگاهی یافت نشد';

  @override
  String get bt_connecting => 'در حال اتصال...';

  @override
  String get bt_connected => 'متصل شد';

  @override
  String get bt_permission_denied =>
      'دسترسی به بلوتوث رد شد. لطفاً آن را در تنظیمات فعال کنید.';

  @override
  String get bt_not_supported_platform =>
      'حالت بلوتوث هنوز در این دستگاه پشتیبانی نمی‌شود. لطفاً از حالت وای‌فای استفاده کنید.';

  @override
  String get open_settings => 'باز کردن تنظیمات';

  @override
  String get retry => 'تلاش مجدد';

  @override
  String get bt_connection_failed => 'اتصال ناموفق بود';

  @override
  String get bt_back => 'بازگشت';

  @override
  String get theme_dark => 'تاریک';

  @override
  String get theme_light => 'روشن';

  @override
  String get noise_filter => 'فیلتر نویز';

  @override
  String get noise_filter_off => 'خاموش';

  @override
  String get noise_filter_weak => 'کم';

  @override
  String get noise_filter_strong => 'زیاد';

  @override
  String get transport_hotspot => 'نقطه اتصال (هات‌اسپات)';

  @override
  String get hotspot_title => 'پل هات‌اسپات';

  @override
  String get hotspot_not_supported =>
      'سیستم میزبان پل هات‌اسپات روی اندروید اجرا می‌شود. در آیفون، به جای این کار به هات‌اسپات یک میزبان اندرویدی متصل شوید.';

  @override
  String get hotspot_host_badge => 'وای‌فای داخلی • میزبان اندروید';

  @override
  String get hotspot_creating => 'در حال ساخت هات‌اسپات...';

  @override
  String get hotspot_waiting => 'در انتظار اتصال آیفون...';

  @override
  String get hotspot_step_scan =>
      'در آیفون، این کد را (با دوربین یا اسکنر درون برنامه) اسکن کرده و روی Join بزنید.';

  @override
  String get hotspot_step_join_channel =>
      'سپس وارد کانال می‌شود — صدا از طریق این ارتباط وای‌فای منتقل می‌شود.';

  @override
  String get hotspot_network => 'شبکه';

  @override
  String get hotspot_password => 'رمز عبور';

  @override
  String get hotspot_copied => 'کپی شد';

  @override
  String get hotspot_enter_channel => 'ورود به کانال';

  @override
  String get hotspot_error =>
      'هات‌اسپات ساخته نشد. هرگونه هات‌اسپات/اشتراک‌گذاری اینترنت فعال را خاموش کنید، مطمئن شوید مکان‌یابی (Location) روشن است، سپس دوباره تلاش کنید.';

  @override
  String get hotspot_ios_instructions =>
      'از گوشی اندرویدی بخواهید برنامه Tark ← Hotspot را باز کند، سپس کد وای‌فای آن را اینجا اسکن کنید.';

  @override
  String get hotspot_scan_host => 'اسکن کد میزبان';

  @override
  String get hotspot_joining => 'در حال اتصال به شبکه...';

  @override
  String get hotspot_joined => 'به شبکه متصل شد';

  @override
  String get hotspot_manual_join_title => 'اتصال دستی به این شبکه';

  @override
  String get hotspot_manual_join_hint =>
      'تنظیمات › Wi-Fi را باز کنید، این شبکه را انتخاب کنید، سپس برگردید و وارد کانال شوید.';

  @override
  String get hotspot_invalid_qr =>
      'این یک کد وای‌فای معتبر نیست. کدی که روی گوشی میزبان اندرویدی نمایش داده می‌شود را اسکن کنید.';

  @override
  String get bt_ios_hint =>
      'ارتباط آیفون ↔ اندروید روی بلوتوث ممکن است پایدار نباشد. برای داشتن پایدارترین ارتباط بین دو گوشی مختلف، از حالت هات‌اسپات استفاده کنید.';

  @override
  String get bt_ble_unavailable =>
      'این گوشی امکان فرستادن سیگنال بلوتوث کم‌مصرف (BLE) را ندارد، بنابراین آیفون‌ها نمی‌توانند آن را در اینجا پیدا کنند.';

  @override
  String get bt_use_wifi_bridge => 'استفاده از پل وای‌فای';

  @override
  String get background_title => 'روشن نگه داشتن کانال هنگام خاموش بودن صفحه';

  @override
  String get background_desc =>
      'برای استفاده حین موتورسواری/دوچرخه‌سواری، اجازه دهید برنامه در پس‌زمینه اجرا شود تا با خاموش شدن صفحه، جریان صدا قطع نشود. بدون این اجازه، ممکن است گوشی وای‌فای را قطع کرده و بی‌صدا شود.';

  @override
  String get background_allow => 'اجازه فعالیت در پس‌زمینه';

  @override
  String get background_autostart => 'شروع خودکار';

  @override
  String get background_dismiss => 'فعلاً نه';

  @override
  String get music_cast_stalled =>
      'سیستم صدای این گوشی هنگام تماس کانال از اشتراک‌گذاری موزیک جلوگیری می‌کند. پخش متوقف شد.';
}
