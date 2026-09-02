import 'package:flutter/widgets.dart';

/// Digit localization for callers that have no [BuildContext] to hand — a
/// stream mapper that outlives the frame it was built in, for instance, where
/// reaching back into a context would be a use-after-unmount waiting to
/// happen. Resolve [farsi] once from the tree, then format freely.
///
/// ## What gets localized, and what must not
///
/// **Quantities the user reads** — member counts, seconds, percentages, sizes,
/// days, step numbers, the version badge — all go through this. A Latin `5`
/// sitting inside an otherwise Persian sentence is the most visible way an app
/// can look half-translated.
///
/// **Identifiers do not.** A Room code, an invite check value, an SSID, a
/// Wi-Fi passphrase or an IP address stays in Latin digits, for two reasons
/// that both bite: they are compared across two phones that may be running
/// different locales, and a Persian `۵` cannot be typed into Android's Wi-Fi
/// dialog. Those sites also carry an explicit `Directionality.ltr`, so an
/// unlocalized identifier is a deliberate pair of decisions rather than a
/// missed one.
String localizeDigits(String value, {required bool farsi}) =>
    farsi ? value._toFarsiDigits() : value._toLatinDigits();

extension StringExt on String {
  /// Converts ASCII digits to locale-specific digits.
  /// Farsi locale → Arabic-Indic digits (۰–۹); otherwise keeps ASCII digits.
  String localized(BuildContext context) =>
      localizeDigits(this, farsi: Localizations.localeOf(context).languageCode == 'fa');

  String _toFarsiDigits() => replaceAll('0', '۰')
      .replaceAll('1', '۱')
      .replaceAll('2', '۲')
      .replaceAll('3', '۳')
      .replaceAll('4', '۴')
      .replaceAll('5', '۵')
      .replaceAll('6', '۶')
      .replaceAll('7', '۷')
      .replaceAll('8', '۸')
      .replaceAll('9', '۹');

  String _toLatinDigits() => replaceAll('۰', '0')
      .replaceAll('۱', '1')
      .replaceAll('۲', '2')
      .replaceAll('۳', '3')
      .replaceAll('۴', '4')
      .replaceAll('۵', '5')
      .replaceAll('۶', '6')
      .replaceAll('۷', '7')
      .replaceAll('۸', '8')
      .replaceAll('۹', '9');

  // Legacy: convert back to Latin digits (e.g. for sending over network)
  String toEnglish() => _toLatinDigits();
}

extension IntExt on int {
  String localized(BuildContext context) => toString().localized(context);
}

extension DoubleExt on double {
  String localized(BuildContext context) => toString().localized(context);

  String localizedFixed(BuildContext context, int fractionDigits) =>
      toStringAsFixed(fractionDigits).localized(context);
}
