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
  /// **'تــرک'**
  String get app_name;

  /// No description provided for @app_subtitle.
  ///
  /// In fa, this message translates to:
  /// **'بیسیم بدون اینترنت'**
  String get app_subtitle;

  /// No description provided for @live.
  ///
  /// In fa, this message translates to:
  /// **'زنده'**
  String get live;

  /// No description provided for @offline.
  ///
  /// In fa, this message translates to:
  /// **'قطع'**
  String get offline;

  /// No description provided for @edit_name.
  ///
  /// In fa, this message translates to:
  /// **'ویرایش'**
  String get edit_name;

  /// No description provided for @connecting.
  ///
  /// In fa, this message translates to:
  /// **'دارم وصل می‌شم...'**
  String get connecting;

  /// No description provided for @monitoring.
  ///
  /// In fa, this message translates to:
  /// **'دارم گوش می‌دم'**
  String get monitoring;

  /// No description provided for @initializing.
  ///
  /// In fa, this message translates to:
  /// **'دارم آماده می‌شم'**
  String get initializing;

  /// No description provided for @tx_label.
  ///
  /// In fa, this message translates to:
  /// **'صحبت'**
  String get tx_label;

  /// No description provided for @rx_label.
  ///
  /// In fa, this message translates to:
  /// **'صدای ورودی'**
  String get rx_label;

  /// No description provided for @music_cast.
  ///
  /// In fa, this message translates to:
  /// **'پخش آهنگ'**
  String get music_cast;

  /// No description provided for @music_cast_hint.
  ///
  /// In fa, this message translates to:
  /// **'هر چی روی این گوشی پخش بشه، همه بچه‌های کانال می‌شنون.'**
  String get music_cast_hint;

  /// No description provided for @music_cast_start.
  ///
  /// In fa, this message translates to:
  /// **'شروع پخش'**
  String get music_cast_start;

  /// No description provided for @music_cast_starting.
  ///
  /// In fa, this message translates to:
  /// **'دارم شروع می‌کنم...'**
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
  /// **'بلندی آهنگ'**
  String get music_cast_mix;

  /// No description provided for @music_cast_silent.
  ///
  /// In fa, this message translates to:
  /// **'هیچی پخش نمی‌شه! برو یه آهنگ بذار.'**
  String get music_cast_silent;

  /// No description provided for @music_cast_stop_hint.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی به اعلان‌ها رو روشن کن تا دکمه توقف، برنامه آهنگت رو هم نگه داره.'**
  String get music_cast_stop_hint;

  /// No description provided for @music_cast_stop_enable.
  ///
  /// In fa, this message translates to:
  /// **'روشن کن'**
  String get music_cast_stop_enable;

  /// No description provided for @channel_members.
  ///
  /// In fa, this message translates to:
  /// **'کیا اینجان'**
  String get channel_members;

  /// No description provided for @no_users_on_network.
  ///
  /// In fa, this message translates to:
  /// **'هنوز کسی اینجا نیست'**
  String get no_users_on_network;

  /// No description provided for @vox_sensitivity.
  ///
  /// In fa, this message translates to:
  /// **'چقدر راحت صدات رو بشنوه'**
  String get vox_sensitivity;

  /// No description provided for @vox_threshold.
  ///
  /// In fa, this message translates to:
  /// **'چقدر بلند حرف بزنی'**
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
  /// **'صدای تو'**
  String get level_label;

  /// No description provided for @level_active.
  ///
  /// In fa, this message translates to:
  /// **'داره می‌ره'**
  String get level_active;

  /// No description provided for @level_silent.
  ///
  /// In fa, this message translates to:
  /// **'ساکت'**
  String get level_silent;

  /// No description provided for @user_idle.
  ///
  /// In fa, this message translates to:
  /// **'ساکت'**
  String get user_idle;

  /// No description provided for @set_name_title.
  ///
  /// In fa, this message translates to:
  /// **'چی صدات کنیم؟'**
  String get set_name_title;

  /// No description provided for @name_hint.
  ///
  /// In fa, this message translates to:
  /// **'اسمت رو بنویس'**
  String get name_hint;

  /// No description provided for @cancel.
  ///
  /// In fa, this message translates to:
  /// **'بی‌خیال'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In fa, this message translates to:
  /// **'ذخیره'**
  String get save;

  /// No description provided for @mic_permission_denied.
  ///
  /// In fa, this message translates to:
  /// **'«ترک» صدات رو نمی‌شنوه. برو توی تنظیمات میکروفون رو روشن کن.'**
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
  /// **'شبکه‌ای پیدا نمی‌کنم'**
  String get no_network;

  /// No description provided for @leave_channel_confirm_title.
  ///
  /// In fa, this message translates to:
  /// **'داری میری؟'**
  String get leave_channel_confirm_title;

  /// No description provided for @leave_channel_confirm_message.
  ///
  /// In fa, this message translates to:
  /// **'اگه بری، ارتباطت با بچه‌های این کانال قطع میشه.'**
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

  /// No description provided for @transport_wifi_hotspot.
  ///
  /// In fa, this message translates to:
  /// **'وای‌فای / هات‌اسپات'**
  String get transport_wifi_hotspot;

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
  /// **'دعوت از مهمون'**
  String get guest_invite_title;

  /// No description provided for @guest_step_scan.
  ///
  /// In fa, this message translates to:
  /// **'مهمونت دوربین گوشیش رو می‌گیره روی این کد و صفحه ورود براش باز می‌شه.'**
  String get guest_step_scan;

  /// No description provided for @guest_step_answer.
  ///
  /// In fa, this message translates to:
  /// **'بعدش یه کد پاسخ روی صفحه‌ش میاد؛ با دکمه زیر اسکنش کن، یا اگه برات فرستاده همین‌جا بچسبونش.'**
  String get guest_step_answer;

  /// No description provided for @guest_scan_answer.
  ///
  /// In fa, this message translates to:
  /// **'اسکن کد پاسخ'**
  String get guest_scan_answer;

  /// No description provided for @guest_link_failed.
  ///
  /// In fa, this message translates to:
  /// **'نشد! یه دعوت‌نامه تازه بساز و دوباره امتحان کن.'**
  String get guest_link_failed;

  /// No description provided for @guest_no_server_badge.
  ///
  /// In fa, this message translates to:
  /// **'بدون واسطه'**
  String get guest_no_server_badge;

  /// No description provided for @guest_copy_link.
  ///
  /// In fa, this message translates to:
  /// **'کپی پیوند'**
  String get guest_copy_link;

  /// No description provided for @guest_link_copied.
  ///
  /// In fa, this message translates to:
  /// **'پیوند دعوت کپی شد!'**
  String get guest_link_copied;

  /// No description provided for @guest_paste_answer.
  ///
  /// In fa, this message translates to:
  /// **'چسبوندن کد پاسخ'**
  String get guest_paste_answer;

  /// No description provided for @guest_paste_answer_hint.
  ///
  /// In fa, this message translates to:
  /// **'کد پاسخی که برات فرستادن رو اینجا بذار'**
  String get guest_paste_answer_hint;

  /// No description provided for @guest_paste_submit.
  ///
  /// In fa, this message translates to:
  /// **'اتصال'**
  String get guest_paste_submit;

  /// No description provided for @guest_stun_caveat.
  ///
  /// In fa, this message translates to:
  /// **'توی بیشتر شبکه‌ها خوب کار می‌کنه؛ ولی چند تا شبکه خیلی سخت‌گیر اداری یا مدرسه ممکنه جلوش رو بگیرن.'**
  String get guest_stun_caveat;

  /// No description provided for @guest_web_scan_title.
  ///
  /// In fa, this message translates to:
  /// **'برای ورود اسکن کن'**
  String get guest_web_scan_title;

  /// No description provided for @guest_web_scan_text.
  ///
  /// In fa, this message translates to:
  /// **'این صفحه رو با اسکن کد QR یا زدن روی پیوند دعوتِ میزبان باز کن.'**
  String get guest_web_scan_text;

  /// No description provided for @guest_web_failed_title.
  ///
  /// In fa, this message translates to:
  /// **'نشد!'**
  String get guest_web_failed_title;

  /// No description provided for @guest_web_failed_text.
  ///
  /// In fa, this message translates to:
  /// **'وصل نشدی. از میزبان یه دعوت‌نامه تازه بگیر و دوباره امتحان کن.'**
  String get guest_web_failed_text;

  /// No description provided for @guest_web_reply_chip.
  ///
  /// In fa, this message translates to:
  /// **'مرحله ۲ — کد پاسخ'**
  String get guest_web_reply_chip;

  /// No description provided for @guest_web_reply_title.
  ///
  /// In fa, this message translates to:
  /// **'این کد رو بگیر جلوی گوشی میزبان'**
  String get guest_web_reply_title;

  /// No description provided for @guest_web_reply_hint.
  ///
  /// In fa, this message translates to:
  /// **'روی گوشی میزبان: «اسکن کد پاسخ» رو بزن و دوربین رو بگیر این‌ور.'**
  String get guest_web_reply_hint;

  /// No description provided for @guest_web_reply_copy.
  ///
  /// In fa, this message translates to:
  /// **'کپی کد'**
  String get guest_web_reply_copy;

  /// No description provided for @guest_web_reply_copied.
  ///
  /// In fa, this message translates to:
  /// **'کد پاسخ کپی شد!'**
  String get guest_web_reply_copied;

  /// No description provided for @guest_web_connected.
  ///
  /// In fa, this message translates to:
  /// **'وصل شدی!'**
  String get guest_web_connected;

  /// No description provided for @guest_web_enable_audio.
  ///
  /// In fa, this message translates to:
  /// **'دکمه زیر رو بزن تا میکروفون و بلندگوت روشن بشه.'**
  String get guest_web_enable_audio;

  /// No description provided for @guest_web_start_audio.
  ///
  /// In fa, this message translates to:
  /// **'شروع صدا'**
  String get guest_web_start_audio;

  /// No description provided for @guest_web_mute.
  ///
  /// In fa, this message translates to:
  /// **'قطع صدا'**
  String get guest_web_mute;

  /// No description provided for @guest_web_unmute.
  ///
  /// In fa, this message translates to:
  /// **'وصل صدا'**
  String get guest_web_unmute;

  /// No description provided for @guest_web_talking.
  ///
  /// In fa, this message translates to:
  /// **'داری حرف می‌زنی...'**
  String get guest_web_talking;

  /// No description provided for @guest_web_on_air.
  ///
  /// In fa, this message translates to:
  /// **'همه صدات رو می‌شنون!'**
  String get guest_web_on_air;

  /// No description provided for @guest_web_standby.
  ///
  /// In fa, this message translates to:
  /// **'منتظرم...'**
  String get guest_web_standby;

  /// No description provided for @guest_web_link_lost.
  ///
  /// In fa, this message translates to:
  /// **'ارتباط قطع شد'**
  String get guest_web_link_lost;

  /// No description provided for @guest_web_link_lost_text.
  ///
  /// In fa, this message translates to:
  /// **'گمت کردم — دارم دوباره تلاش می‌کنم...'**
  String get guest_web_link_lost_text;

  /// No description provided for @guest_web_left_title.
  ///
  /// In fa, this message translates to:
  /// **'از کانال اومدی بیرون'**
  String get guest_web_left_title;

  /// No description provided for @guest_web_left_text.
  ///
  /// In fa, this message translates to:
  /// **'ارتباطت قطع شد. می‌خوای برگردی؟ از میزبان یه دعوت‌نامه تازه بگیر و دوباره اسکن کن.'**
  String get guest_web_left_text;

  /// No description provided for @bt_start_session.
  ///
  /// In fa, this message translates to:
  /// **'شروع ارتباط'**
  String get bt_start_session;

  /// No description provided for @bt_role_host_desc.
  ///
  /// In fa, this message translates to:
  /// **'بذار گوشی دیگه این گوشی رو پیدا کنه و بپره وسط.'**
  String get bt_role_host_desc;

  /// No description provided for @bt_find_nearby.
  ///
  /// In fa, this message translates to:
  /// **'پیدا کردن گوشی‌های نزدیک'**
  String get bt_find_nearby;

  /// No description provided for @bt_role_join_desc.
  ///
  /// In fa, this message translates to:
  /// **'یه دور بگرد و به گوشی‌ای که منتظره وصل شو.'**
  String get bt_role_join_desc;

  /// No description provided for @bt_visible_as.
  ///
  /// In fa, this message translates to:
  /// **'بقیه تو رو این‌طور می‌بینن'**
  String get bt_visible_as;

  /// No description provided for @bt_last_session.
  ///
  /// In fa, this message translates to:
  /// **'آخرین ارتباط'**
  String get bt_last_session;

  /// No description provided for @bt_reconnect.
  ///
  /// In fa, this message translates to:
  /// **'دوباره وصل شو'**
  String get bt_reconnect;

  /// No description provided for @bt_link_reconnecting.
  ///
  /// In fa, this message translates to:
  /// **'بلوتوث قطع شد — دارم دوباره تلاش می‌کنم...'**
  String get bt_link_reconnecting;

  /// No description provided for @bt_link_down.
  ///
  /// In fa, this message translates to:
  /// **'ارتباط بلوتوث قطع شد'**
  String get bt_link_down;

  /// No description provided for @bt_waiting_for_peer.
  ///
  /// In fa, this message translates to:
  /// **'منتظر گوشی دیگه‌ام...'**
  String get bt_waiting_for_peer;

  /// No description provided for @bt_scanning.
  ///
  /// In fa, this message translates to:
  /// **'دارم می‌گردم...'**
  String get bt_scanning;

  /// No description provided for @bt_no_devices_found.
  ///
  /// In fa, this message translates to:
  /// **'این دور و بر چیزی نیست'**
  String get bt_no_devices_found;

  /// No description provided for @bt_connecting.
  ///
  /// In fa, this message translates to:
  /// **'دارم وصل می‌شم...'**
  String get bt_connecting;

  /// No description provided for @bt_connected.
  ///
  /// In fa, this message translates to:
  /// **'وصل شدی!'**
  String get bt_connected;

  /// No description provided for @bt_permission_denied.
  ///
  /// In fa, this message translates to:
  /// **'«ترک» نمی‌تونه از بلوتوث استفاده کنه. برو توی تنظیمات روشنش کن.'**
  String get bt_permission_denied;

  /// No description provided for @bt_not_supported_platform.
  ///
  /// In fa, this message translates to:
  /// **'بلوتوث فعلاً روی این گوشی کار نمی‌کنه — به‌جاش از وای‌فای برو.'**
  String get bt_not_supported_platform;

  /// No description provided for @open_settings.
  ///
  /// In fa, this message translates to:
  /// **'باز کردن تنظیمات'**
  String get open_settings;

  /// No description provided for @retry.
  ///
  /// In fa, this message translates to:
  /// **'دوباره امتحان کن'**
  String get retry;

  /// No description provided for @permissions_title.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی‌ها'**
  String get permissions_title;

  /// No description provided for @permission_granted.
  ///
  /// In fa, this message translates to:
  /// **'اوکیه'**
  String get permission_granted;

  /// No description provided for @permission_grant.
  ///
  /// In fa, this message translates to:
  /// **'اجازه بده'**
  String get permission_grant;

  /// No description provided for @permission_mic_title.
  ///
  /// In fa, this message translates to:
  /// **'میکروفون'**
  String get permission_mic_title;

  /// No description provided for @permission_mic_desc.
  ///
  /// In fa, this message translates to:
  /// **'تا برنامه بتونه صدات رو بگیره و بفرسته.'**
  String get permission_mic_desc;

  /// No description provided for @permission_bluetooth_title.
  ///
  /// In fa, this message translates to:
  /// **'بلوتوث'**
  String get permission_bluetooth_title;

  /// No description provided for @permission_bluetooth_desc.
  ///
  /// In fa, this message translates to:
  /// **'تا برنامه بتونه گوشی‌های نزدیک رو با بلوتوث پیدا کنه و بهشون وصل بشه.'**
  String get permission_bluetooth_desc;

  /// No description provided for @permission_bt_scan_title.
  ///
  /// In fa, this message translates to:
  /// **'گشتن دنبال گوشی‌ها'**
  String get permission_bt_scan_title;

  /// No description provided for @permission_bt_scan_desc.
  ///
  /// In fa, this message translates to:
  /// **'گوشی‌های نزدیک رو که می‌تونی بهشون وصل بشی پیدا می‌کنه.'**
  String get permission_bt_scan_desc;

  /// No description provided for @permission_bt_connect_title.
  ///
  /// In fa, this message translates to:
  /// **'اتصال'**
  String get permission_bt_connect_title;

  /// No description provided for @permission_bt_connect_desc.
  ///
  /// In fa, this message translates to:
  /// **'به گوشی دیگه وصل می‌شه و صدا رو بینتون رد و بدل می‌کنه.'**
  String get permission_bt_connect_desc;

  /// No description provided for @permission_bt_advertise_title.
  ///
  /// In fa, this message translates to:
  /// **'دیده شدن'**
  String get permission_bt_advertise_title;

  /// No description provided for @permission_bt_advertise_desc.
  ///
  /// In fa, this message translates to:
  /// **'وقتی تو ارتباط رو راه می‌ندازی، می‌ذاره گوشی دیگه ببیندت.'**
  String get permission_bt_advertise_desc;

  /// No description provided for @permission_hotspot_title.
  ///
  /// In fa, this message translates to:
  /// **'موقعیت مکانی و وای‌فای نزدیک'**
  String get permission_hotspot_title;

  /// No description provided for @permission_hotspot_desc.
  ///
  /// In fa, this message translates to:
  /// **'اندروید این رو می‌خواد تا گوشیت بتونه هات‌اسپات بسازه و بقیه بپرن توش.'**
  String get permission_hotspot_desc;

  /// No description provided for @permission_battery_title.
  ///
  /// In fa, this message translates to:
  /// **'روشن ماندن با صفحه خاموش'**
  String get permission_battery_title;

  /// No description provided for @permission_battery_desc.
  ///
  /// In fa, this message translates to:
  /// **'کانال رو موقع خاموش بودن صفحه زنده نگه می‌داره — بدون این، ممکنه گوشی وسط راه برنامه رو ببنده.'**
  String get permission_battery_desc;

  /// No description provided for @bt_connection_failed.
  ///
  /// In fa, this message translates to:
  /// **'نشد!'**
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
  /// **'صدای مزاحم اطراف'**
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

  /// No description provided for @settings_advanced_row.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات ریزتر'**
  String get settings_advanced_row;

  /// No description provided for @settings_advanced_row_desc.
  ///
  /// In fa, this message translates to:
  /// **'چیزهای اضافه برای ور رفتن — بیشتر آدم‌ها اصلاً بهشون کار ندارن'**
  String get settings_advanced_row_desc;

  /// No description provided for @settings_advanced_title.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات ریزتر'**
  String get settings_advanced_title;

  /// No description provided for @noise_cleaner_section.
  ///
  /// In fa, this message translates to:
  /// **'حذف صداهای مزاحم'**
  String get noise_cleaner_section;

  /// No description provided for @noise_cleaner_intro.
  ///
  /// In fa, this message translates to:
  /// **'انتخاب کن برنامه چطور صداهای مزاحم اطراف رو موقع حرف زدنت پاک کنه.'**
  String get noise_cleaner_intro;

  /// No description provided for @noise_cleaner_simple_title.
  ///
  /// In fa, this message translates to:
  /// **'پاک‌کن ساده'**
  String get noise_cleaner_simple_title;

  /// No description provided for @noise_cleaner_simple_desc.
  ///
  /// In fa, this message translates to:
  /// **'صداهای یکنواخت مثل پنکه یا موتور رو کم می‌کنه.'**
  String get noise_cleaner_simple_desc;

  /// No description provided for @noise_cleaner_simple_downside.
  ///
  /// In fa, this message translates to:
  /// **'صدای باد و خیابون ممکنه رد بشه.'**
  String get noise_cleaner_simple_downside;

  /// No description provided for @noise_cleaner_smart_title.
  ///
  /// In fa, this message translates to:
  /// **'پاک‌کن هوشمند'**
  String get noise_cleaner_smart_title;

  /// No description provided for @noise_cleaner_smart_desc.
  ///
  /// In fa, this message translates to:
  /// **'یاد گرفته صدای مزاحم چه شکلیه، واسه همین صدای باد و خیابون رو هم پاک می‌کنه.'**
  String get noise_cleaner_smart_desc;

  /// No description provided for @noise_cleaner_smart_downside.
  ///
  /// In fa, this message translates to:
  /// **'باتری بیشتری می‌خوره.'**
  String get noise_cleaner_smart_downside;

  /// No description provided for @noise_cleaner_both_title.
  ///
  /// In fa, this message translates to:
  /// **'هر دو با هم'**
  String get noise_cleaner_both_title;

  /// No description provided for @noise_cleaner_both_desc.
  ///
  /// In fa, this message translates to:
  /// **'هر دو پاک‌کن پشت سر هم کار می‌کنن تا صدا از همه تمیزتر بشه.'**
  String get noise_cleaner_both_desc;

  /// No description provided for @noise_cleaner_both_downside.
  ///
  /// In fa, this message translates to:
  /// **'بیشترین باتری رو می‌خوره و صدات ممکنه یه کم نازک بشه.'**
  String get noise_cleaner_both_downside;

  /// No description provided for @noise_cleaner_downside_label.
  ///
  /// In fa, this message translates to:
  /// **'نکته منفی'**
  String get noise_cleaner_downside_label;

  /// No description provided for @noise_cleaner_unavailable.
  ///
  /// In fa, this message translates to:
  /// **'پاک‌کن هوشمند هنوز روی این گوشی آماده نیست، پس فعلاً پاک‌کن ساده کار می‌کنه.'**
  String get noise_cleaner_unavailable;

  /// No description provided for @sfx_feedback.
  ///
  /// In fa, this message translates to:
  /// **'بوق و صداهای برنامه'**
  String get sfx_feedback;

  /// No description provided for @link_reconnecting.
  ///
  /// In fa, this message translates to:
  /// **'گمت کردم — دارم دوباره تلاش می‌کنم...'**
  String get link_reconnecting;

  /// No description provided for @link_reconnecting_in.
  ///
  /// In fa, this message translates to:
  /// **'تا {seconds} ثانیه دیگه دوباره تلاش می‌کنم'**
  String link_reconnecting_in(Object seconds);

  /// No description provided for @link_down.
  ///
  /// In fa, this message translates to:
  /// **'ارتباط قطع شد'**
  String get link_down;

  /// No description provided for @transport_hotspot.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات'**
  String get transport_hotspot;

  /// No description provided for @hotspot_title.
  ///
  /// In fa, this message translates to:
  /// **'راه‌اندازی هات‌اسپات'**
  String get hotspot_title;

  /// No description provided for @wifi_only_instructions.
  ///
  /// In fa, this message translates to:
  /// **'از قبل رو یه وای‌فای هستی؟ چیزی لازم نیست تنظیم کنی — بپر تو کانال.'**
  String get wifi_only_instructions;

  /// No description provided for @wifi_only_step_same_network.
  ///
  /// In fa, this message translates to:
  /// **'حواست باشه هر دو گوشی رو یه وای‌فای باشن.'**
  String get wifi_only_step_same_network;

  /// No description provided for @hotspot_not_supported.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات فقط رو اندروید و آیفون کار می‌کنه.'**
  String get hotspot_not_supported;

  /// No description provided for @hotspot_role_title.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی کدوم طرفه؟'**
  String get hotspot_role_title;

  /// No description provided for @hotspot_role_hint.
  ///
  /// In fa, this message translates to:
  /// **'یه گوشی شبکه رو می‌سازه، اون یکی کدش رو اسکن می‌کنه.'**
  String get hotspot_role_hint;

  /// No description provided for @hotspot_role_host.
  ///
  /// In fa, this message translates to:
  /// **'ساخت هات‌اسپات'**
  String get hotspot_role_host;

  /// No description provided for @hotspot_role_host_desc.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی شبکه رو می‌سازه و یه کد نشون می‌ده تا گوشی دیگه اسکنش کنه.'**
  String get hotspot_role_host_desc;

  /// No description provided for @hotspot_role_join.
  ///
  /// In fa, this message translates to:
  /// **'اتصال به یک هات‌اسپات'**
  String get hotspot_role_join;

  /// No description provided for @hotspot_role_join_desc.
  ///
  /// In fa, this message translates to:
  /// **'کد روی گوشی‌ای که شبکه رو ساخته اسکن کن.'**
  String get hotspot_role_join_desc;

  /// No description provided for @hotspot_host_badge.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات ترک • روی آنتن'**
  String get hotspot_host_badge;

  /// No description provided for @hotspot_show_credentials.
  ///
  /// In fa, this message translates to:
  /// **'اسکن نمی‌شه؟ مشخصات شبکه رو ببین'**
  String get hotspot_show_credentials;

  /// No description provided for @hotspot_hide_credentials.
  ///
  /// In fa, this message translates to:
  /// **'پنهانش کن'**
  String get hotspot_hide_credentials;

  /// No description provided for @hotspot_network_note.
  ///
  /// In fa, this message translates to:
  /// **'این اسم رو خود اندروید می‌ذاره و هیچ برنامه‌ای نمی‌تونه عوضش کنه. همین هات‌اسپات ترکه — گوشی دیگه هم اصلاً لازم نیست بخونتش، کد رو اسکن کنه کافیه.'**
  String get hotspot_network_note;

  /// No description provided for @hotspot_creating.
  ///
  /// In fa, this message translates to:
  /// **'دارم هات‌اسپات می‌سازم...'**
  String get hotspot_creating;

  /// No description provided for @hotspot_waiting.
  ///
  /// In fa, this message translates to:
  /// **'منتظر گوشی دیگه‌ام...'**
  String get hotspot_waiting;

  /// No description provided for @hotspot_step_scan.
  ///
  /// In fa, this message translates to:
  /// **'رو گوشی دیگه، «ترک» ← هات‌اسپات ← اتصال به یک هات‌اسپات رو باز کن و این کد رو اسکن کن.'**
  String get hotspot_step_scan;

  /// No description provided for @hotspot_step_join_channel.
  ///
  /// In fa, this message translates to:
  /// **'بعدش می‌پره تو کانال و صداتون از رو همین وای‌فای رد و بدل می‌شه.'**
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
  /// **'کپی شد!'**
  String get hotspot_copied;

  /// No description provided for @hotspot_enter_channel.
  ///
  /// In fa, this message translates to:
  /// **'ورود به کانال'**
  String get hotspot_enter_channel;

  /// No description provided for @hotspot_error.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات ساخته نشد. دوباره امتحان کن، یا بذار گوشی دیگه بسازدش.'**
  String get hotspot_error;

  /// No description provided for @hotspot_error_tethering.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات خود گوشی روشنه. خاموشش کن و دوباره امتحان کن.'**
  String get hotspot_error_tethering;

  /// No description provided for @hotspot_error_location.
  ///
  /// In fa, this message translates to:
  /// **'اندروید تا «موقعیت مکانی» روشن نباشه هات‌اسپات نمی‌سازه.'**
  String get hotspot_error_location;

  /// No description provided for @hotspot_error_permission.
  ///
  /// In fa, this message translates to:
  /// **'«ترک» باید بتونه وای‌فای‌های نزدیک رو ببینه تا هات‌اسپات بسازه. اجازه بده و دوباره امتحان کن.'**
  String get hotspot_error_permission;

  /// No description provided for @hotspot_error_no_channel.
  ///
  /// In fa, this message translates to:
  /// **'الان جای خالی رو وای‌فای نیست. از وای‌فایی که روشی جدا شو و دوباره امتحان کن.'**
  String get hotspot_error_no_channel;

  /// No description provided for @hotspot_error_incompatible.
  ///
  /// In fa, this message translates to:
  /// **'وای‌فای درگیر یه کار دیگه‌ست. وای‌فای رو خاموش و روشن کن و دوباره امتحان کن.'**
  String get hotspot_error_incompatible;

  /// No description provided for @hotspot_error_unsupported.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی نمی‌تونه هات‌اسپات خودش رو بسازه — اندروید ۸ یا جدیدتر می‌خواد.'**
  String get hotspot_error_unsupported;

  /// No description provided for @hotspot_open_settings.
  ///
  /// In fa, this message translates to:
  /// **'باز کردن تنظیمات'**
  String get hotspot_open_settings;

  /// No description provided for @hotspot_try_joining.
  ///
  /// In fa, this message translates to:
  /// **'به جاش به گوشی دیگه وصل شو'**
  String get hotspot_try_joining;

  /// No description provided for @hotspot_join_instructions.
  ///
  /// In fa, this message translates to:
  /// **'از گوشی دیگه بخواه «ساخت هات‌اسپات» رو باز کنه، بعد کدش رو اینجا اسکن کن.'**
  String get hotspot_join_instructions;

  /// No description provided for @hotspot_scan_host.
  ///
  /// In fa, this message translates to:
  /// **'اسکن کد میزبان'**
  String get hotspot_scan_host;

  /// No description provided for @hotspot_scan_hint.
  ///
  /// In fa, this message translates to:
  /// **'دوربین رو بگیر رو کد گوشی دیگه.'**
  String get hotspot_scan_hint;

  /// No description provided for @hotspot_scan_camera_denied.
  ///
  /// In fa, this message translates to:
  /// **'«ترک» برای خوندن کد میزبان دوربین می‌خواد.'**
  String get hotspot_scan_camera_denied;

  /// No description provided for @hotspot_scan_camera_failed.
  ///
  /// In fa, this message translates to:
  /// **'دوربین باز نشد. هر چی دیگه ازش استفاده می‌کنه رو ببند و دوباره امتحان کن.'**
  String get hotspot_scan_camera_failed;

  /// No description provided for @hotspot_scan_searching.
  ///
  /// In fa, this message translates to:
  /// **'دارم دنبال کد می‌گردم'**
  String get hotspot_scan_searching;

  /// No description provided for @hotspot_scan_locked.
  ///
  /// In fa, this message translates to:
  /// **'کد پیدا شد'**
  String get hotspot_scan_locked;

  /// No description provided for @hotspot_scan_again.
  ///
  /// In fa, this message translates to:
  /// **'اسکن دوباره'**
  String get hotspot_scan_again;

  /// No description provided for @hotspot_joining.
  ///
  /// In fa, this message translates to:
  /// **'دارم به شبکه وصل می‌شم...'**
  String get hotspot_joining;

  /// No description provided for @hotspot_joined.
  ///
  /// In fa, this message translates to:
  /// **'رو شبکه‌ای!'**
  String get hotspot_joined;

  /// No description provided for @hotspot_joined_network.
  ///
  /// In fa, this message translates to:
  /// **'وصل شدی به {network}'**
  String hotspot_joined_network(Object network);

  /// No description provided for @hotspot_join_waiting.
  ///
  /// In fa, this message translates to:
  /// **'بپر تو کانال تا حرف بزنیم.'**
  String get hotspot_join_waiting;

  /// No description provided for @hotspot_link_lost.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات غیبش زد. دوباره وصل شو تا برگردی.'**
  String get hotspot_link_lost;

  /// No description provided for @hotspot_rejoin.
  ///
  /// In fa, this message translates to:
  /// **'دوباره وصل شو'**
  String get hotspot_rejoin;

  /// No description provided for @hotspot_manual_join_title.
  ///
  /// In fa, this message translates to:
  /// **'خودت به این شبکه وصل شو'**
  String get hotspot_manual_join_title;

  /// No description provided for @hotspot_manual_join_hint.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات › وای‌فای رو باز کن، این شبکه رو انتخاب کن، بعد برگرد و دکمه زیر رو بزن.'**
  String get hotspot_manual_join_hint;

  /// No description provided for @hotspot_manual_joined.
  ///
  /// In fa, this message translates to:
  /// **'وصل شدم!'**
  String get hotspot_manual_joined;

  /// No description provided for @hotspot_invalid_qr.
  ///
  /// In fa, this message translates to:
  /// **'این کد وای‌فای نیست. همونی که رو گوشی میزبانه رو اسکن کن.'**
  String get hotspot_invalid_qr;

  /// No description provided for @bt_ios_hint.
  ///
  /// In fa, this message translates to:
  /// **'بلوتوث بین آیفون و اندروید زیاد قطع می‌شه. برای یه چیز پایدارتر، از هات‌اسپات برو.'**
  String get bt_ios_hint;

  /// No description provided for @bt_ble_unavailable.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی نمی‌تونه خودش رو با بلوتوث به بقیه نشون بده، واسه همین آیفون‌ها اینجا نمی‌بیننش.'**
  String get bt_ble_unavailable;

  /// No description provided for @bt_use_wifi_bridge.
  ///
  /// In fa, this message translates to:
  /// **'به جاش از وای‌فای برو'**
  String get bt_use_wifi_bridge;

  /// No description provided for @background_title.
  ///
  /// In fa, this message translates to:
  /// **'با صفحه خاموش هم حرف بزن'**
  String get background_title;

  /// No description provided for @background_desc.
  ///
  /// In fa, this message translates to:
  /// **'موقع رانندگی، بذار برنامه بعد از خاموش شدن صفحه هم کار کنه تا صدا قطع نشه. وگرنه ممکنه گوشی وای‌فای رو ول کنه و همه‌جا ساکت بشه.'**
  String get background_desc;

  /// No description provided for @background_allow.
  ///
  /// In fa, this message translates to:
  /// **'بذار روشن بمونه'**
  String get background_allow;

  /// No description provided for @background_autostart.
  ///
  /// In fa, this message translates to:
  /// **'خودش شروع کنه'**
  String get background_autostart;

  /// No description provided for @background_dismiss.
  ///
  /// In fa, this message translates to:
  /// **'بعداً'**
  String get background_dismiss;

  /// No description provided for @music_cast_stalled.
  ///
  /// In fa, this message translates to:
  /// **'این گوشی وسط تماس کانال آهنگ پخش نمی‌کنه. پخش قطع شد.'**
  String get music_cast_stalled;

  /// No description provided for @settings_title.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات'**
  String get settings_title;

  /// No description provided for @settings_section_identity.
  ///
  /// In fa, this message translates to:
  /// **'درباره تو'**
  String get settings_section_identity;

  /// No description provided for @settings_section_voice.
  ///
  /// In fa, this message translates to:
  /// **'صدا و میکروفون'**
  String get settings_section_voice;

  /// No description provided for @settings_section_sound.
  ///
  /// In fa, this message translates to:
  /// **'بوق‌ها و هشدارها'**
  String get settings_section_sound;

  /// No description provided for @settings_section_appearance.
  ///
  /// In fa, this message translates to:
  /// **'ظاهر برنامه'**
  String get settings_section_appearance;

  /// No description provided for @settings_section_connection.
  ///
  /// In fa, this message translates to:
  /// **'اتصال'**
  String get settings_section_connection;

  /// No description provided for @settings_section_startup.
  ///
  /// In fa, this message translates to:
  /// **'وقتی برنامه باز می‌شه'**
  String get settings_section_startup;

  /// No description provided for @settings_applies_live.
  ///
  /// In fa, this message translates to:
  /// **'همین الان رو کانالت اثر می‌ذاره'**
  String get settings_applies_live;

  /// No description provided for @settings_applies_next_session.
  ///
  /// In fa, this message translates to:
  /// **'دفعه بعد که رفتی تو کانال اثر می‌ذاره'**
  String get settings_applies_next_session;

  /// No description provided for @settings_quick_access.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی سریع'**
  String get settings_quick_access;

  /// No description provided for @settings_quick_access_desc.
  ///
  /// In fa, this message translates to:
  /// **'این صفحه رو رد کن و یه‌راست برگرد تو آخرین کانالت'**
  String get settings_quick_access_desc;

  /// No description provided for @settings_delay.
  ///
  /// In fa, this message translates to:
  /// **'تاخیر در پخش صدا'**
  String get settings_delay;

  /// No description provided for @settings_delay_desc.
  ///
  /// In fa, this message translates to:
  /// **'برنامه قبل از پخش صدا یه کم صبر می‌کنه. صبرِ بیشتر صدای بریده‌بریده رو روون‌تر می‌کنه — ولی صدای دوستت رو یه کم دیرتر می‌شنوی.'**
  String get settings_delay_desc;

  /// No description provided for @settings_delay_low_hint.
  ///
  /// In fa, this message translates to:
  /// **'زودتر بشنو'**
  String get settings_delay_low_hint;

  /// No description provided for @settings_delay_high_hint.
  ///
  /// In fa, this message translates to:
  /// **'صدای روون‌تر'**
  String get settings_delay_high_hint;

  /// No description provided for @settings_restore_defaults.
  ///
  /// In fa, this message translates to:
  /// **'برگردون به حالت اول'**
  String get settings_restore_defaults;

  /// No description provided for @settings_restore_defaults_done.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات صدا برگشت به حالت اول.'**
  String get settings_restore_defaults_done;

  /// No description provided for @settings_auto_reconnect.
  ///
  /// In fa, this message translates to:
  /// **'خودش دوباره وصل بشه'**
  String get settings_auto_reconnect;

  /// No description provided for @settings_auto_reconnect_desc.
  ///
  /// In fa, this message translates to:
  /// **'وقتی ارتباط قطع شد خودش برمی‌گرده، و وقتی اومدی آخرین گوشی بلوتوثیت رو هم پیدا می‌کنه.'**
  String get settings_auto_reconnect_desc;

  /// No description provided for @settings_permissions_row.
  ///
  /// In fa, this message translates to:
  /// **'دسترسی‌ها'**
  String get settings_permissions_row;

  /// No description provided for @settings_permissions_row_desc.
  ///
  /// In fa, this message translates to:
  /// **'ببین و عوض کن که برنامه به چه چیزهایی کار داره'**
  String get settings_permissions_row_desc;

  /// No description provided for @settings_wifi_hotspot_row.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات وای‌فای / هات‌اسپات'**
  String get settings_wifi_hotspot_row;

  /// No description provided for @settings_wifi_hotspot_row_desc.
  ///
  /// In fa, this message translates to:
  /// **'هات‌اسپات بساز، یا ببین چطور با وای‌فای وصل بشی'**
  String get settings_wifi_hotspot_row_desc;

  /// No description provided for @settings_skip_splash.
  ///
  /// In fa, this message translates to:
  /// **'رد کردن صفحه خوش‌آمدگویی'**
  String get settings_skip_splash;

  /// No description provided for @settings_skip_splash_desc.
  ///
  /// In fa, this message translates to:
  /// **'یه‌راست بپر تو برنامه'**
  String get settings_skip_splash_desc;

  /// No description provided for @usage_tips_title.
  ///
  /// In fa, this message translates to:
  /// **'استفاده بهینه از «ترک»'**
  String get usage_tips_title;

  /// No description provided for @usage_tips_1_title.
  ///
  /// In fa, this message translates to:
  /// **'هدفونی بزن که صدای اطراف رو کم می‌کنه'**
  String get usage_tips_1_title;

  /// No description provided for @usage_tips_1_body.
  ///
  /// In fa, this message translates to:
  /// **'هدفونی که صدای اطراف رو کم می‌کنه، شنیدن کانال رو با وجود باد و صدای موتور خیلی راحت‌تر می‌کنه — دستات هم موقع حرکت آزاد می‌مونه.'**
  String get usage_tips_1_body;

  /// No description provided for @usage_tips_2_title.
  ///
  /// In fa, this message translates to:
  /// **'همیشه از کلاه ایمنی مناسب استفاده کن'**
  String get usage_tips_2_title;

  /// No description provided for @usage_tips_2_body.
  ///
  /// In fa, this message translates to:
  /// **'اول ایمنی! کلاه ایمنیِ اندازه، هدفون رو هم به گوشات نزدیک‌تر نگه می‌داره تا صدا رو واضح‌تر بشنوی.'**
  String get usage_tips_2_body;

  /// No description provided for @usage_tips_3_title.
  ///
  /// In fa, this message translates to:
  /// **'برای حرف زدن لازم نیست دکمه‌ای بزنی'**
  String get usage_tips_3_title;

  /// No description provided for @usage_tips_3_body.
  ///
  /// In fa, this message translates to:
  /// **'میکروفون همیشه حواسش به توئه و برنامه صداهای مزاحم رو پاک می‌کنه، پس فقط حرف بزن. هر وقت خواستی هر دو رو توی تنظیمات دستکاری کن.'**
  String get usage_tips_3_body;

  /// No description provided for @usage_tips_dismiss.
  ///
  /// In fa, this message translates to:
  /// **'فهمیدم'**
  String get usage_tips_dismiss;

  /// No description provided for @usage_tips_next.
  ///
  /// In fa, this message translates to:
  /// **'بعدی'**
  String get usage_tips_next;

  /// No description provided for @settings_gear_tooltip.
  ///
  /// In fa, this message translates to:
  /// **'تنظیمات'**
  String get settings_gear_tooltip;

  /// No description provided for @onboarding_welcome_title.
  ///
  /// In fa, this message translates to:
  /// **'یه بیسیم رو شبکه خودت'**
  String get onboarding_welcome_title;

  /// No description provided for @onboarding_welcome_sub.
  ///
  /// In fa, this message translates to:
  /// **'با گوشی‌های نزدیک بدون اینترنت حرف بزن — مستقیم، سریع و خصوصی.'**
  String get onboarding_welcome_sub;

  /// No description provided for @onboarding_info_lan.
  ///
  /// In fa, this message translates to:
  /// **'رو وای‌فای مشترک یا هات‌اسپات کار می‌کنه'**
  String get onboarding_info_lan;

  /// No description provided for @onboarding_info_private.
  ///
  /// In fa, this message translates to:
  /// **'بدون حساب کاربری، بدون واسطه — صدات هیچ‌وقت از شبکه خودت بیرون نمی‌ره'**
  String get onboarding_info_private;

  /// No description provided for @onboarding_info_vox.
  ///
  /// In fa, this message translates to:
  /// **'دکمه‌ای در کار نیست — فقط حرف بزن تا همه بشنون'**
  String get onboarding_info_vox;

  /// No description provided for @onboarding_skip.
  ///
  /// In fa, this message translates to:
  /// **'رد کردن'**
  String get onboarding_skip;

  /// No description provided for @onboarding_begin.
  ///
  /// In fa, this message translates to:
  /// **'شروع راه‌اندازی'**
  String get onboarding_begin;

  /// No description provided for @onboarding_continue.
  ///
  /// In fa, this message translates to:
  /// **'ادامه'**
  String get onboarding_continue;

  /// No description provided for @onboarding_finish.
  ///
  /// In fa, this message translates to:
  /// **'بزن بریم'**
  String get onboarding_finish;

  /// No description provided for @onboarding_callsign_title.
  ///
  /// In fa, this message translates to:
  /// **'اسم بیسیمیت رو انتخاب کن'**
  String get onboarding_callsign_title;

  /// No description provided for @onboarding_callsign_help.
  ///
  /// In fa, this message translates to:
  /// **'بچه‌های کانال تو رو با این اسم می‌بینن.'**
  String get onboarding_callsign_help;

  /// No description provided for @onboarding_mode_title.
  ///
  /// In fa, this message translates to:
  /// **'چطور وصل می‌شی؟'**
  String get onboarding_mode_title;

  /// No description provided for @onboarding_mode_help.
  ///
  /// In fa, this message translates to:
  /// **'هر وقت خواستی می‌تونی توی تنظیمات عوضش کنی.'**
  String get onboarding_mode_help;

  /// No description provided for @onboarding_mode_wifi_desc.
  ///
  /// In fa, this message translates to:
  /// **'همه رو یه وای‌فای — تمیزترین صدا و بیشترین برد'**
  String get onboarding_mode_wifi_desc;

  /// No description provided for @onboarding_mode_bluetooth_desc.
  ///
  /// In fa, this message translates to:
  /// **'دو تا گوشی مستقیم به هم، بدون هیچ شبکه‌ای'**
  String get onboarding_mode_bluetooth_desc;

  /// No description provided for @onboarding_mode_guest_desc.
  ///
  /// In fa, this message translates to:
  /// **'مهمون‌ها با اسکن یه کد QR از مرورگر می‌پرن تو'**
  String get onboarding_mode_guest_desc;

  /// No description provided for @onboarding_ready_title.
  ///
  /// In fa, this message translates to:
  /// **'همه چیز آماده‌ست'**
  String get onboarding_ready_title;

  /// No description provided for @onboarding_ready_sub.
  ///
  /// In fa, this message translates to:
  /// **'این هم کارت بیسیمت — کانال تو رو این‌طوری می‌بینه.'**
  String get onboarding_ready_sub;

  /// No description provided for @onboarding_tip_vox.
  ///
  /// In fa, this message translates to:
  /// **'دکمه‌ای لازم نیست — فقط حرف بزن تا همه بشنون.'**
  String get onboarding_tip_vox;

  /// No description provided for @onboarding_tip_settings.
  ///
  /// In fa, this message translates to:
  /// **'اسمت، نحوه وصل شدنت و میکروفونت، همه توی تنظیمات هستن.'**
  String get onboarding_tip_settings;

  /// No description provided for @onboarding_tune_title.
  ///
  /// In fa, this message translates to:
  /// **'شخصی‌سازی برنامه'**
  String get onboarding_tune_title;

  /// No description provided for @onboarding_tune_sub.
  ///
  /// In fa, this message translates to:
  /// **'زبان و ظاهر برنامه رو انتخاب کن — هر وقت خواستی عوضشون کن.'**
  String get onboarding_tune_sub;

  /// No description provided for @onboarding_language_label.
  ///
  /// In fa, this message translates to:
  /// **'زبان'**
  String get onboarding_language_label;

  /// No description provided for @onboarding_theme_label.
  ///
  /// In fa, this message translates to:
  /// **'ظاهر'**
  String get onboarding_theme_label;

  /// No description provided for @onboarding_signal.
  ///
  /// In fa, this message translates to:
  /// **'سیگنال'**
  String get onboarding_signal;

  /// No description provided for @onboarding_stamp_ready.
  ///
  /// In fa, this message translates to:
  /// **'آماده'**
  String get onboarding_stamp_ready;

  /// No description provided for @onboarding_explore.
  ///
  /// In fa, this message translates to:
  /// **'اول یه نگاهی به دور و بر بنداز'**
  String get onboarding_explore;

  /// No description provided for @onboarding_callsign_pool.
  ///
  /// In fa, this message translates to:
  /// **'شاهین,افعی,پژواک,طوفان,شبح,عقاب,پلنگ,سیمرغ'**
  String get onboarding_callsign_pool;

  /// No description provided for @settings_replay_intro.
  ///
  /// In fa, this message translates to:
  /// **'پخش دوباره راهنما'**
  String get settings_replay_intro;

  /// No description provided for @settings_replay_intro_desc.
  ///
  /// In fa, this message translates to:
  /// **'مراحل خوش‌آمدگویی و تنظیم اولیه رو دوباره ببین'**
  String get settings_replay_intro_desc;
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
