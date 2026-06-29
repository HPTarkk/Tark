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
  /// **'واکی تاکی'**
  String get app_name;

  /// No description provided for @app_subtitle.
  ///
  /// In fa, this message translates to:
  /// **'بی‌سیم شبکه محلی'**
  String get app_subtitle;

  /// No description provided for @live.
  ///
  /// In fa, this message translates to:
  /// **'آنلاین'**
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
  /// **'در حال پایش...'**
  String get monitoring;

  /// No description provided for @initializing.
  ///
  /// In fa, this message translates to:
  /// **'در حال راه‌اندازی'**
  String get initializing;

  /// No description provided for @tx_label.
  ///
  /// In fa, this message translates to:
  /// **'TX'**
  String get tx_label;

  /// No description provided for @rx_label.
  ///
  /// In fa, this message translates to:
  /// **'RX'**
  String get rx_label;

  /// No description provided for @channel_members.
  ///
  /// In fa, this message translates to:
  /// **'اعضای کانال'**
  String get channel_members;

  /// No description provided for @no_users_on_network.
  ///
  /// In fa, this message translates to:
  /// **'هیچ کاربری در این شبکه نیست'**
  String get no_users_on_network;

  /// No description provided for @vox_sensitivity.
  ///
  /// In fa, this message translates to:
  /// **'حساسیت VOX'**
  String get vox_sensitivity;

  /// No description provided for @vox_threshold.
  ///
  /// In fa, this message translates to:
  /// **'آستانه'**
  String get vox_threshold;

  /// No description provided for @voice_loud.
  ///
  /// In fa, this message translates to:
  /// **'صدای بلند'**
  String get voice_loud;

  /// No description provided for @voice_quiet.
  ///
  /// In fa, this message translates to:
  /// **'صدای آرام'**
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
  /// **'ساکت'**
  String get level_silent;

  /// No description provided for @user_idle.
  ///
  /// In fa, this message translates to:
  /// **'آماده'**
  String get user_idle;

  /// No description provided for @set_name_title.
  ///
  /// In fa, this message translates to:
  /// **'نام خود را تنظیم کنید'**
  String get set_name_title;

  /// No description provided for @name_hint.
  ///
  /// In fa, this message translates to:
  /// **'نام خود را وارد کنید'**
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
  /// **'دسترسی به میکروفن رد شد. لطفاً در تنظیمات مجوز دسترسی را فعال کنید.'**
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
  /// **'ارتباط شما با سایر اعضای کانال قطع خواهد شد.'**
  String get leave_channel_confirm_message;

  /// No description provided for @leave.
  ///
  /// In fa, this message translates to:
  /// **'خروج'**
  String get leave;
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
