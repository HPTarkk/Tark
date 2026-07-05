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
      'موزیک و صدای برنامه‌های این گوشی را برای همهٔ اعضای کانال پخش کن.';

  @override
  String get music_cast_start => 'شروع پخش';

  @override
  String get music_cast_starting => 'در حال شروع...';

  @override
  String get music_cast_stop => 'توقف';

  @override
  String get music_cast_on_air => 'روی آنتن';

  @override
  String get music_cast_mix => 'میزان صدای موزیک';

  @override
  String get music_cast_silent =>
      'صدایی پخش نمی‌شود — در برنامهٔ موزیک، آهنگی پخش کن';

  @override
  String get channel_members => 'اعضای کانال';

  @override
  String get no_users_on_network => 'کاربر دیگری در این شبکه حضور ندارد';

  @override
  String get vox_sensitivity => 'حساسیت VOX';

  @override
  String get vox_threshold => 'آستانه صدا';

  @override
  String get voice_loud => 'بلند';

  @override
  String get voice_quiet => 'آهسته';

  @override
  String get level_label => 'سطح';

  @override
  String get level_active => 'فعال';

  @override
  String get level_silent => 'سکوت';

  @override
  String get user_idle => 'بیکار';

  @override
  String get set_name_title => 'انتخاب نام شما';

  @override
  String get name_hint => 'نام خود را وارد کنید';

  @override
  String get cancel => 'لغو';

  @override
  String get save => 'ذخیره';

  @override
  String get mic_permission_denied =>
      'دسترسی به میکروفون داده نشد. لطفاً آن را در تنظیمات فعال کنید.';

  @override
  String get join_channel => 'ورود به کانال';

  @override
  String get leave_channel => 'خروج از کانال';

  @override
  String get no_network => 'شبکه‌ای یافت نشد';

  @override
  String get leave_channel_confirm_title => 'از کانال خارج می‌شوید؟';

  @override
  String get leave_channel_confirm_message =>
      'اتصال شما با سایر اعضای حاضر در این کانال قطع خواهد شد.';

  @override
  String get leave => 'خروج';

  @override
  String get transport_wifi => 'وای‌فای';

  @override
  String get transport_bluetooth => 'بلوتوث';

  @override
  String get transport_guest => 'مهمان';

  @override
  String get guest_invite_title => 'دعوت مهمان';

  @override
  String get guest_step_scan =>
      'مهمان این کد را با دوربین گوشی‌اش اسکن می‌کند — صفحهٔ ورود در مرورگرش باز می‌شود (هر دو دستگاه روی یک وای‌فای).';

  @override
  String get guest_step_answer =>
      'سپس روی صفحهٔ مهمان یک کد پاسخ نمایش داده می‌شود — با دکمهٔ زیر آن را اسکن کن.';

  @override
  String get guest_scan_answer => 'اسکن کد پاسخ';

  @override
  String get guest_link_failed =>
      'برقراری ارتباط ممکن نشد. یک دعوت جدید بساز و دوباره تلاش کن.';

  @override
  String get guest_web_scan_title => 'برای پیوستن اسکن کن';

  @override
  String get guest_web_scan_text =>
      'این صفحه را با اسکن کد دعوت روی گوشی میزبان باز کن — خودِ لینک حامل اتصال است.';

  @override
  String get guest_web_failed_title => 'ارتباط برقرار نشد';

  @override
  String get guest_web_failed_text =>
      'اتصال برقرار نشد. از میزبان بخواه دعوت جدیدی بسازد و دوباره اسکن کن (هر دو دستگاه باید روی یک وای‌فای باشند).';

  @override
  String get guest_web_reply_chip => 'مرحله ۲ — کد پاسخ';

  @override
  String get guest_web_reply_title => 'این کد را به گوشی میزبان نشان بده';

  @override
  String get guest_web_reply_hint =>
      'در گوشی میزبان: «اسکن کد پاسخ» را بزن و دوربین را به این‌جا بگیر.';

  @override
  String get guest_web_connected => 'متصل شد!';

  @override
  String get guest_web_enable_audio =>
      'برای فعال‌شدن میکروفون و بلندگو دکمهٔ زیر را بزن.';

  @override
  String get guest_web_start_audio => 'شروع صدا';

  @override
  String get guest_web_mute => 'بی‌صدا';

  @override
  String get guest_web_unmute => 'وصل صدا';

  @override
  String get guest_web_talking => 'در حال صحبت...';

  @override
  String get guest_web_on_air => 'روی آنتن هستی';

  @override
  String get guest_web_standby => 'در حالت آماده‌باش';

  @override
  String get guest_web_link_lost => 'قطع ارتباط';

  @override
  String get guest_web_link_lost_text => 'ارتباط قطع شد — در انتظار اتصال...';

  @override
  String get guest_web_left_title => 'از کانال خارج شدی';

  @override
  String get guest_web_left_text =>
      'اتصال قطع شد. برای بازگشت، از میزبان یک دعوت تازه بگیر و دوباره اسکن کن.';

  @override
  String get bt_start_session => 'شروع نشست';

  @override
  String get bt_role_host_desc =>
      'یک نشست بساز تا دستگاه مقابل آن را پیدا کند و بپیوندد';

  @override
  String get bt_find_nearby => 'جستجوی نزدیک';

  @override
  String get bt_role_join_desc => 'اطراف را بگرد و به نشست نزدیک متصل شو';

  @override
  String get bt_visible_as => 'قابل مشاهده با نام';

  @override
  String get bt_last_session => 'نشست قبلی';

  @override
  String get bt_reconnect => 'اتصال مجدد';

  @override
  String get bt_link_reconnecting =>
      'اتصال بلوتوث قطع شد — در حال اتصال مجدد...';

  @override
  String get bt_waiting_for_peer => 'در انتظار اتصال طرف مقابل...';

  @override
  String get bt_scanning => 'در حال جستجو...';

  @override
  String get bt_no_devices_found => 'دستگاهی یافت نشد';

  @override
  String get bt_connecting => 'در حال اتصال...';

  @override
  String get bt_connected => 'متصل شد';

  @override
  String get bt_permission_denied =>
      'دسترسی بلوتوث داده نشد. لطفاً آن را در تنظیمات فعال کنید.';

  @override
  String get bt_not_supported_platform =>
      'حالت بلوتوث هنوز روی این دستگاه در دسترس نیست. لطفاً از حالت وای‌فای استفاده کنید.';

  @override
  String get open_settings => 'باز کردن تنظیمات';

  @override
  String get retry => 'تلاش دوباره';

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
  String get transport_hotspot => 'هات‌اسپات';

  @override
  String get hotspot_title => 'پل هات‌اسپات';

  @override
  String get hotspot_not_supported =>
      'میزبانِ پل هات‌اسپات روی اندروید اجرا می‌شود. روی آیفون، به هات‌اسپاتِ یک میزبان اندرویدی بپیوند.';

  @override
  String get hotspot_host_badge => 'وای‌فای محلی • میزبان اندروید';

  @override
  String get hotspot_creating => 'در حال ساخت هات‌اسپات...';

  @override
  String get hotspot_waiting => 'در انتظار پیوستن آیفون...';

  @override
  String get hotspot_step_scan =>
      'روی آیفون، این کد را (با دوربین یا اسکنر داخل برنامه) اسکن کن و «پیوستن» را بزن.';

  @override
  String get hotspot_step_join_channel =>
      'سپس وارد کانال می‌شود — صدا از روی همین لینک وای‌فای جریان می‌یابد.';

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
      'ساخت هات‌اسپات ممکن نشد. هر هات‌اسپات یا اشتراک‌گذاری فعال را خاموش کن، مطمئن شو موقعیت مکانی روشن است، سپس دوباره تلاش کن.';

  @override
  String get hotspot_ios_instructions =>
      'از گوشی اندرویدی بخواه تَرک ← هات‌اسپات را باز کند، سپس کد وای‌فای آن را این‌جا اسکن کن.';

  @override
  String get hotspot_scan_host => 'اسکن کد میزبان';

  @override
  String get hotspot_joining => 'در حال پیوستن به شبکه...';

  @override
  String get hotspot_joined => 'به شبکه پیوستی';

  @override
  String get hotspot_manual_join_title => 'پیوستن دستی به این شبکه';

  @override
  String get hotspot_manual_join_hint =>
      'تنظیمات ← وای‌فای را باز کن، این شبکه را انتخاب کن، بعد برگرد و وارد کانال شو.';

  @override
  String get hotspot_invalid_qr =>
      'این یک کد وای‌فای نیست. کدی را که روی میزبان اندروید نمایش داده می‌شود اسکن کن.';

  @override
  String get bt_ios_hint =>
      'بلوتوث بین آیفون و اندروید ممکن است پایدار نباشد. برای مطمئن‌ترین اتصال بین دو گوشی، از حالت هات‌اسپات استفاده کن.';

  @override
  String get bt_ble_unavailable =>
      'این گوشی نمی‌تواند روی بلوتوث LE تبلیغ کند، پس آیفون‌ها آن را این‌جا پیدا نمی‌کنند.';

  @override
  String get bt_use_wifi_bridge => 'استفاده از پل وای‌فای';
}
