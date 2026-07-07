import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa'),
  ];

  /// No description provided for @app_name.
  ///
  /// In fa, this message translates to:
  /// **'تَرک'**
  String get app_name;

  /// No description provided for @app_subtitle.
  ///
  /// In fa, this message translates to:
  /// **'واکی تاکی شبکه داخلی'**
  String get app_subtitle;

  /// No description provided for @live.
  ///
  /// In fa, this message translates to:
  /// **'زنده'**
  String get live;

  /// No description provided for @offline.
  ///
  /// In fa, this message translates to:
  /// **'آفلاین'**
  String get offline;

  /// No description provided for @edit_name.
  ///
  /// In fa, this message translates to:
  /// **'ویرایش'**
  String get edit_name;

  /// No description provided for @connecting.
  ///
  /// In fa, this message translates to:
  /// **'در حال اتصال...'**
  String get connecting;

  /// No description provided for @monitoring.
  ///
  /// In fa, this message translates to:
  /// **'در حال پایش'**
  String get monitoring;

  /// No description provided for @initializing.
  ///
  /// In fa, this message translates to:
  /// **'در حال راه‌اندازی'**
  String get initializing;

  /// No description provided for @tx_label.
  ///
  /// In fa, this message translates to:
  /// **'ارسال (TX)'**
  String get tx_label;

  /// No description provided for @rx_label.
  ///
  /// In fa, this message translates to:
  /// **'دریافت (RX)'**
  String get rx_label;

  /// No description provided for @music_cast.
  ///
  /// In fa, this message translates to:
  /// **'پخش موزیک'**
  String get music_cast;

  /// No description provided for @music_cast_hint.
  ///
  /// In fa, this message translates to:
  /// **'پخش موزیک و صداهای برنامه‌های این گوشی برای همه افراد در کانال.'**
  String get music_cast_hint;

  /// No description provided for @music_cast_start.
  ///
  /// In fa, this message translates to:
  /// **'شروع پخش'**
  String get music_cast_start;

  /// No description provided for @music_cast_starting.
  ///
  /// In fa, this message translates to:
  /// **'در حال شروع...'**
  String get music_cast_starting;

  /// No description provided for @music_cast_stop.
  ///
  /// In fa, this message translates to:
  /// **'توقف'**
  String get music_cast_stop;

  /// No description provided for @music_cast_on_air.
  ///
  /// In fa, this message translates to:
  /// **'در حال پخش'**
  String get music_cast_on_air;

  /// No description provided for @music_cast_mix.
  ///
  /// In fa, this message translates to:
  /// **'سطح ترکیب صدا'**
  String get music_cast_mix;

  /// No description provided for @music_cast_silent.
  ///
  /// In fa, this message translates to:
  /// **'چیزی در حال پخش نیست — یک آهنگ در برنامه موزیک خود اجرا کنید'**
  String get music_cast_silent;

  /// No description provided for @music_cast_stop_hint.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی اعلان‌ها را فعال کنید تا دکمه توقف، برنامه موزیک را هم متوقف کند'**
  String get music_cast_stop_hint;

  /// No description provided for @music_cast_stop_enable.
  ///
  /// In fa, this message translates to:
  /// **'فعال‌سازی'**
  String get music_cast_stop_enable;

  /// No description provided for @channel_members.
  ///
  /// In fa, this message translates to:
  /// **'اعضای کانال'**
  String get channel_members;

  /// No description provided for @no_users_on_network.
  ///
  /// In fa, this message translates to:
  /// **'کاربر دیگری در این شبکه وجود ندارد'**
  String get no_users_on_network;

  /// No description provided for @vox_sensitivity.
  ///
  /// In fa, this message translates to:
  /// **'حساسیت VOX'**
  String get vox_sensitivity;

  /// No description provided for @vox_threshold.
  ///
  /// In fa, this message translates to:
  /// **'آستانه صدا'**
  String get vox_threshold;

  /// No description provided for @voice_loud.
  ///
  /// In fa, this message translates to:
  /// **'بلند'**
  String get voice_loud;

  /// No description provided for @voice_quiet.
  ///
  /// In fa, this message translates to:
  /// **'آرام'**
  String get voice_quiet;

  /// No description provided for @level_label.
  ///
  /// In fa, this message translates to:
  /// **'سطح'**
  String get level_label;

  /// No description provided for @level_active.
  ///
  /// In fa, this message translates to:
  /// **'فعال'**
  String get level_active;

  /// No description provided for @level_silent.
  ///
  /// In fa, this message translates to:
  /// **'بی‌صدا'**
  String get level_silent;

  /// No description provided for @user_idle.
  ///
  /// In fa, this message translates to:
  /// **'بیکار'**
  String get user_idle;

  /// No description provided for @set_name_title.
  ///
  /// In fa, this message translates to:
  /// **'نام خود را وارد کنید'**
  String get set_name_title;

  /// No description provided for @name_hint.
  ///
  /// In fa, this message translates to:
  /// **'نام خود را بنویسید'**
  String get name_hint;

  /// No description provided for @cancel.
  ///
  /// In fa, this message translates to:
  /// **'لغو'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In fa, this message translates to:
  /// **'ذخیره'**
  String get save;

  /// No description provided for @mic_permission_denied.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی به میکروفون رد شد. لطفاً آن را در تنظیمات فعال کنید.'**
  String get mic_permission_denied;

  /// No description provided for @join_channel.
  ///
  /// In fa, this message translates to:
  /// **'ورود به کانال'**
  String get join_channel;

  /// No description provided for @leave_channel.
  ///
  /// In fa, this message translates to:
  /// **'خروج از کانال'**
  String get leave_channel;

  /// No description provided for @no_network.
  ///
  /// In fa, this message translates to:
  /// **'شبکه‌ای یافت نشد'**
  String get no_network;

  /// No description provided for @leave_channel_confirm_title.
  ///
  /// In fa, this message translates to:
  /// **'خروج از کانال؟'**
  String get leave_channel_confirm_title;

  /// No description provided for @leave_channel_confirm_message.
  ///
  /// In fa, this message translates to:
  /// **'اتصال شما با سایر اعضای این کانال قطع خواهد شد.'**
  String get leave_channel_confirm_message;

  /// No description provided for @leave.
  ///
  /// In fa, this message translates to:
  /// **'خروج'**
  String get leave;

  /// No description provided for @transport_wifi.
  ///
  /// In fa, this message translates to:
  /// **'وای‌فای'**
  String get transport_wifi;

  /// No description provided for @transport_bluetooth.
  ///
  /// In fa, this message translates to:
  /// **'بلوتوث'**
  String get transport_bluetooth;

  /// No description provided for @transport_guest.
  ///
  /// In fa, this message translates to:
  /// **'مهمان'**
  String get transport_guest;

  /// No description provided for @guest_invite_title.
  ///
  /// In fa, this message translates to:
  /// **'دعوت از مهمان'**
  String get guest_invite_title;

  /// No description provided for @guest_step_scan.
  ///
  /// In fa, this message translates to:
  /// **'مهمان این کد را با دوربین گوشی خود اسکن می‌کند — صفحه ورود در مرورگر او باز می‌شود.'**
  String get guest_step_scan;

  /// No description provided for @guest_step_answer.
  ///
  /// In fa, this message translates to:
  /// **'سپس یک کد پاسخ روی صفحه او نشان داده می‌شود — آن را با دکمه زیر اسکن کنید، یا اگر برایتان فرستاده، آن را بچسبانید.'**
  String get guest_step_answer;

  /// No description provided for @guest_scan_answer.
  ///
  /// In fa, this message translates to:
  /// **'اسکن کد پاسخ'**
  String get guest_scan_answer;

  /// No description provided for @guest_link_failed.
  ///
  /// In fa, this message translates to:
  /// **'اتصال برقرار نشد. یک دعوت‌نامه جدید بسازید و دوباره تلاش کنید.'**
  String get guest_link_failed;

  /// No description provided for @guest_no_server_badge.
  ///
  /// In fa, this message translates to:
  /// **'بدون سرور'**
  String get guest_no_server_badge;

  /// No description provided for @guest_copy_link.
  ///
  /// In fa, this message translates to:
  /// **'کپی لینک'**
  String get guest_copy_link;

  /// No description provided for @guest_link_copied.
  ///
  /// In fa, this message translates to:
  /// **'لینک دعوت کپی شد'**
  String get guest_link_copied;

  /// No description provided for @guest_paste_answer.
  ///
  /// In fa, this message translates to:
  /// **'چسباندن پاسخ آن‌ها'**
  String get guest_paste_answer;

  /// No description provided for @guest_paste_answer_hint.
  ///
  /// In fa, this message translates to:
  /// **'کد پاسخی که برایتان فرستاده‌اند را اینجا بچسبانید'**
  String get guest_paste_answer_hint;

  /// No description provided for @guest_paste_submit.
  ///
  /// In fa, this message translates to:
  /// **'اتصال'**
  String get guest_paste_submit;

  /// No description provided for @guest_stun_caveat.
  ///
  /// In fa, this message translates to:
  /// **'روی بیشتر شبکه‌ها از طریق اینترنت کار می‌کند. برخی شبکه‌های محدود/سازمانی ممکن است همچنان اتصال را مسدود کنند.'**
  String get guest_stun_caveat;

  /// No description provided for @guest_web_scan_title.
  ///
  /// In fa, this message translates to:
  /// **'اسکن برای ورود'**
  String get guest_web_scan_title;

  /// No description provided for @guest_web_scan_text.
  ///
  /// In fa, this message translates to:
  /// **'این صفحه را با اسکن کردن کد QR دعوت، یا باز کردن لینک دعوت، از گوشی میزبان باز کنید.'**
  String get guest_web_scan_text;

  /// No description provided for @guest_web_failed_title.
  ///
  /// In fa, this message translates to:
  /// **'خطا در اتصال'**
  String get guest_web_failed_title;

  /// No description provided for @guest_web_failed_text.
  ///
  /// In fa, this message translates to:
  /// **'اتصال برقرار نشد. از میزبان بخواهید یک دعوت‌نامه جدید بسازد و دوباره تلاش کنید.'**
  String get guest_web_failed_text;

  /// No description provided for @guest_web_reply_chip.
  ///
  /// In fa, this message translates to:
  /// **'مرحله ۲ — کد پاسخ'**
  String get guest_web_reply_chip;

  /// No description provided for @guest_web_reply_title.
  ///
  /// In fa, this message translates to:
  /// **'این کد را به گوشی میزبان نشان دهید'**
  String get guest_web_reply_title;

  /// No description provided for @guest_web_reply_hint.
  ///
  /// In fa, this message translates to:
  /// **'در گوشی میزبان: روی \"اسکن کد پاسخ\" بزنید و دوربین را به این سمت بگیرید.'**
  String get guest_web_reply_hint;

  /// No description provided for @guest_web_reply_copy.
  ///
  /// In fa, this message translates to:
  /// **'کپی کد'**
  String get guest_web_reply_copy;

  /// No description provided for @guest_web_reply_copied.
  ///
  /// In fa, this message translates to:
  /// **'کد پاسخ کپی شد'**
  String get guest_web_reply_copied;

  /// No description provided for @guest_web_connected.
  ///
  /// In fa, this message translates to:
  /// **'متصل شد!'**
  String get guest_web_connected;

  /// No description provided for @guest_web_enable_audio.
  ///
  /// In fa, this message translates to:
  /// **'برای فعال کردن میکروفون و بلندگوی خود، روی دکمه زیر بزنید.'**
  String get guest_web_enable_audio;

  /// No description provided for @guest_web_start_audio.
  ///
  /// In fa, this message translates to:
  /// **'شروع صدا'**
  String get guest_web_start_audio;

  /// No description provided for @guest_web_mute.
  ///
  /// In fa, this message translates to:
  /// **'بی‌صدا'**
  String get guest_web_mute;

  /// No description provided for @guest_web_unmute.
  ///
  /// In fa, this message translates to:
  /// **'صدادار'**
  String get guest_web_unmute;

  /// No description provided for @guest_web_talking.
  ///
  /// In fa, this message translates to:
  /// **'در حال صحبت...'**
  String get guest_web_talking;

  /// No description provided for @guest_web_on_air.
  ///
  /// In fa, this message translates to:
  /// **'صدای شما در حال پخش است'**
  String get guest_web_on_air;

  /// No description provided for @guest_web_standby.
  ///
  /// In fa, this message translates to:
  /// **'آماده‌به‌کار'**
  String get guest_web_standby;

  /// No description provided for @guest_web_link_lost.
  ///
  /// In fa, this message translates to:
  /// **'قطع اتصال'**
  String get guest_web_link_lost;

  /// No description provided for @guest_web_link_lost_text.
  ///
  /// In fa, this message translates to:
  /// **'اتصال قطع شد — در حال انتظار...'**
  String get guest_web_link_lost_text;

  /// No description provided for @guest_web_left_title.
  ///
  /// In fa, this message translates to:
  /// **'شما کانال را ترک کردید'**
  String get guest_web_left_title;

  /// No description provided for @guest_web_left_text.
  ///
  /// In fa, this message translates to:
  /// **'ارتباط شما قطع شد. برای ورود مجدد، از میزبان یک دعوت‌نامه جدید بگیرید و دوباره اسکن کنید.'**
  String get guest_web_left_text;

  /// No description provided for @bt_start_session.
  ///
  /// In fa, this message translates to:
  /// **'شروع نشست'**
  String get bt_start_session;

  /// No description provided for @bt_role_host_desc.
  ///
  /// In fa, this message translates to:
  /// **'پخش سیگنال نشست تا دستگاه‌های دیگر بتوانند آن را پیدا کرده و متصل شوند'**
  String get bt_role_host_desc;

  /// No description provided for @bt_find_nearby.
  ///
  /// In fa, this message translates to:
  /// **'جستجوی اطراف'**
  String get bt_find_nearby;

  /// No description provided for @bt_role_join_desc.
  ///
  /// In fa, this message translates to:
  /// **'اسکن محیط و اتصال به یک نشست در نزدیک'**
  String get bt_role_join_desc;

  /// No description provided for @bt_visible_as.
  ///
  /// In fa, this message translates to:
  /// **'قابل رویت با نام'**
  String get bt_visible_as;

  /// No description provided for @bt_last_session.
  ///
  /// In fa, this message translates to:
  /// **'آخرین نشست'**
  String get bt_last_session;

  /// No description provided for @bt_reconnect.
  ///
  /// In fa, this message translates to:
  /// **'اتصال مجدد'**
  String get bt_reconnect;

  /// No description provided for @bt_link_reconnecting.
  ///
  /// In fa, this message translates to:
  /// **'اتصال بلوتوث قطع شد — در حال اتصال مجدد...'**
  String get bt_link_reconnecting;

  /// No description provided for @bt_waiting_for_peer.
  ///
  /// In fa, this message translates to:
  /// **'در انتظار اتصال طرف مقابل...'**
  String get bt_waiting_for_peer;

  /// No description provided for @bt_scanning.
  ///
  /// In fa, this message translates to:
  /// **'در حال اسکن...'**
  String get bt_scanning;

  /// No description provided for @bt_no_devices_found.
  ///
  /// In fa, this message translates to:
  /// **'دستگاهی یافت نشد'**
  String get bt_no_devices_found;

  /// No description provided for @bt_connecting.
  ///
  /// In fa, this message translates to:
  /// **'در حال اتصال...'**
  String get bt_connecting;

  /// No description provided for @bt_connected.
  ///
  /// In fa, this message translates to:
  /// **'متصل شد'**
  String get bt_connected;

  /// No description provided for @bt_permission_denied.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی به بلوتوث رد شد. لطفاً آن را در تنظیمات فعال کنید.'**
  String get bt_permission_denied;

  /// No description provided for @bt_not_supported_platform.
  ///
  /// In fa, this message translates to:
  /// **'حالت بلوتوث هنوز در این دستگاه پشتیبانی نمی‌شود. لطفاً از حالت وای‌فای استفاده کنید.'**
  String get bt_not_supported_platform;

  /// No description provided for @open_settings.
  ///
  /// In fa, this message translates to:
  /// **'باز کردن تنظیمات'**
  String get open_settings;

  /// No description provided for @retry.
  ///
  /// In fa, this message translates to:
  /// **'تلاش مجدد'**
  String get retry;

  /// No description provided for @bt_connection_failed.
  ///
  /// In fa, this message translates to:
  /// **'اتصال ناموفق بود'**
  String get bt_connection_failed;

  /// No description provided for @bt_back.
  ///
  /// In fa, this message translates to:
  /// **'بازگشت'**
  String get bt_back;

  /// No description provided for @theme_dark.
  ///
  /// In fa, this message translates to:
  /// **'تاریک'**
  String get theme_dark;

  /// No description provided for @theme_light.
  ///
  /// In fa, this message translates to:
  /// **'روشن'**
  String get theme_light;

  /// No description provided for @noise_filter.
  ///
  /// In fa, this message translates to:
  /// **'فیلتر نویز'**
  String get noise_filter;

  /// No description provided for @noise_filter_off.
  ///
  /// In fa, this message translates to:
  /// **'خاموش'**
  String get noise_filter_off;

  /// No description provided for @noise_filter_weak.
  ///
  /// In fa, this message translates to:
  /// **'کم'**
  String get noise_filter_weak;

  /// No description provided for @noise_filter_strong.
  ///
  /// In fa, this message translates to:
  /// **'زیاد'**
  String get noise_filter_strong;

  /// No description provided for @sfx_feedback.
  ///
  /// In fa, this message translates to:
  /// **'بازخورد صوتی'**
  String get sfx_feedback;

  /// No description provided for @link_reconnecting.
  ///
  /// In fa, this message translates to:
  /// **'اتصال قطع شد — در حال اتصال مجدد...'**
  String get link_reconnecting;

  /// No description provided for @transport_hotspot.
  ///
  /// In fa, this message translates to:
  /// **'نقطه اتصال (هات‌اسپات)'**
  String get transport_hotspot;

  /// No description provided for @hotspot_title.
  ///
  /// In fa, this message translates to:
  /// **'پل هات‌اسپات'**
  String get hotspot_title;

  /// No description provided for @hotspot_not_supported.
  ///
  /// In fa, this message translates to:
  /// **'سیستم میزبان پل هات‌اسپات روی اندروید اجرا می‌شود. در آیفون، به جای این کار به هات‌اسپات یک میزبان اندرویدی متصل شوید.'**
  String get hotspot_not_supported;

  /// No description provided for @hotspot_host_badge.
  ///
  /// In fa, this message translates to:
  /// **'وای‌فای داخلی • میزبان اندروید'**
  String get hotspot_host_badge;

  /// No description provided for @hotspot_creating.
  ///
  /// In fa, this message translates to:
  /// **'در حال ساخت هات‌اسپات...'**
  String get hotspot_creating;

  /// No description provided for @hotspot_waiting.
  ///
  /// In fa, this message translates to:
  /// **'در انتظار اتصال آیفون...'**
  String get hotspot_waiting;

  /// No description provided for @hotspot_step_scan.
  ///
  /// In fa, this message translates to:
  /// **'در آیفون، این کد را (با دوربین یا اسکنر درون برنامه) اسکن کرده و روی Join بزنید.'**
  String get hotspot_step_scan;

  /// No description provided for @hotspot_step_join_channel.
  ///
  /// In fa, this message translates to:
  /// **'سپس وارد کانال می‌شود — صدا از طریق این ارتباط وای‌فای منتقل می‌شود.'**
  String get hotspot_step_join_channel;

  /// No description provided for @hotspot_network.
  ///
  /// In fa, this message translates to:
  /// **'شبکه'**
  String get hotspot_network;

  /// No description provided for @hotspot_password.
  ///
  /// In fa, this message translates to:
  /// **'رمز عبور'**
  String get hotspot_password;

  /// No description provided for @hotspot_copied.
  ///
  /// In fa, this message translates to:
  /// **'کپی شد'**
  String get hotspot_copied;

  /// No description provided for @hotspot_enter_channel.
  ///
  /// In fa, this message translates to:
  /// **'ورود به کانال'**
  String get hotspot_enter_channel;

  /// No description provided for @hotspot_error.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات ساخته نشد. هرگونه هات‌اسپات/اشتراک‌گذاری اینترنت فعال را خاموش کنید، مطمئن شوید مکان‌یابی (Location) روشن است، سپس دوباره تلاش کنید.'**
  String get hotspot_error;

  /// No description provided for @hotspot_ios_instructions.
  ///
  /// In fa, this message translates to:
  /// **'از گوشی اندرویدی بخواهید برنامه Tark ← Hotspot را باز کند، سپس کد وای‌فای آن را اینجا اسکن کنید.'**
  String get hotspot_ios_instructions;

  /// No description provided for @hotspot_scan_host.
  ///
  /// In fa, this message translates to:
  /// **'اسکن کد میزبان'**
  String get hotspot_scan_host;

  /// No description provided for @hotspot_joining.
  ///
  /// In fa, this message translates to:
  /// **'در حال اتصال به شبکه...'**
  String get hotspot_joining;

  /// No description provided for @hotspot_joined.
  ///
  /// In fa, this message translates to:
  /// **'به شبکه متصل شد'**
  String get hotspot_joined;

  /// No description provided for @hotspot_manual_join_title.
  ///
  /// In fa, this message translates to:
  /// **'اتصال دستی به این شبکه'**
  String get hotspot_manual_join_title;

  /// No description provided for @hotspot_manual_join_hint.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات › Wi-Fi را باز کنید، این شبکه را انتخاب کنید، سپس برگردید و وارد کانال شوید.'**
  String get hotspot_manual_join_hint;

  /// No description provided for @hotspot_invalid_qr.
  ///
  /// In fa, this message translates to:
  /// **'این یک کد وای‌فای معتبر نیست. کدی که روی گوشی میزبان اندرویدی نمایش داده می‌شود را اسکن کنید.'**
  String get hotspot_invalid_qr;

  /// No description provided for @bt_ios_hint.
  ///
  /// In fa, this message translates to:
  /// **'ارتباط آیفون ↔ اندروید روی بلوتوث ممکن است پایدار نباشد. برای داشتن پایدارترین ارتباط بین دو گوشی مختلف، از حالت هات‌اسپات استفاده کنید.'**
  String get bt_ios_hint;

  /// No description provided for @bt_ble_unavailable.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی امکان فرستادن سیگنال بلوتوث کم‌مصرف (BLE) را ندارد، بنابراین آیفون‌ها نمی‌توانند آن را در اینجا پیدا کنند.'**
  String get bt_ble_unavailable;

  /// No description provided for @bt_use_wifi_bridge.
  ///
  /// In fa, this message translates to:
  /// **'استفاده از پل وای‌فای'**
  String get bt_use_wifi_bridge;

  /// No description provided for @background_title.
  ///
  /// In fa, this message translates to:
  /// **'روشن نگه داشتن کانال هنگام خاموش بودن صفحه'**
  String get background_title;

  /// No description provided for @background_desc.
  ///
  /// In fa, this message translates to:
  /// **'برای استفاده حین موتورسواری/دوچرخه‌سواری، اجازه دهید برنامه در پس‌زمینه اجرا شود تا با خاموش شدن صفحه، جریان صدا قطع نشود. بدون این اجازه، ممکن است گوشی وای‌فای را قطع کرده و بی‌صدا شود.'**
  String get background_desc;

  /// No description provided for @background_allow.
  ///
  /// In fa, this message translates to:
  /// **'اجازه فعالیت در پس‌زمینه'**
  String get background_allow;

  /// No description provided for @background_autostart.
  ///
  /// In fa, this message translates to:
  /// **'شروع خودکار'**
  String get background_autostart;

  /// No description provided for @background_dismiss.
  ///
  /// In fa, this message translates to:
  /// **'فعلاً نه'**
  String get background_dismiss;

  /// No description provided for @music_cast_stalled.
  ///
  /// In fa, this message translates to:
  /// **'سیستم صدای این گوشی هنگام تماس کانال از اشتراک‌گذاری موزیک جلوگیری می‌کند. پخش متوقف شد.'**
  String get music_cast_stalled;

  /// No description provided for @settings_title.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات'**
  String get settings_title;

  /// No description provided for @settings_section_identity.
  ///
  /// In fa, this message translates to:
  /// **'هویت'**
  String get settings_section_identity;

  /// No description provided for @settings_section_voice.
  ///
  /// In fa, this message translates to:
  /// **'صدا'**
  String get settings_section_voice;

  /// No description provided for @settings_section_sound.
  ///
  /// In fa, this message translates to:
  /// **'صدا و هشدارها'**
  String get settings_section_sound;

  /// No description provided for @settings_section_appearance.
  ///
  /// In fa, this message translates to:
  /// **'ظاهر'**
  String get settings_section_appearance;

  /// No description provided for @settings_section_connection.
  ///
  /// In fa, this message translates to:
  /// **'اتصال'**
  String get settings_section_connection;

  /// No description provided for @settings_applies_live.
  ///
  /// In fa, this message translates to:
  /// **'بلافاصله روی کانال فعلی اعمال می‌شود'**
  String get settings_applies_live;

  /// No description provided for @settings_applies_next_session.
  ///
  /// In fa, this message translates to:
  /// **'دفعه بعد که وارد کانال شوید اعمال می‌شود'**
  String get settings_applies_next_session;

  /// No description provided for @settings_quick_access.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی سریع'**
  String get settings_quick_access;

  /// No description provided for @settings_quick_access_desc.
  ///
  /// In fa, this message translates to:
  /// **'رد شدن از این صفحه و ازسرگیری آخرین کانال هنگام باز کردن اپ'**
  String get settings_quick_access_desc;

  /// No description provided for @settings_gear_tooltip.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات'**
  String get settings_gear_tooltip;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
