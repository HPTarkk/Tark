import 'package:flutter/widgets.dart';

import 'numerals.dart';

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
///
/// Arabic-Indic digits (`٠-٩`, from an Arabic keyboard or a paste) are folded
/// in too, so a value reads in one script whichever keyboard produced it. See
/// `numerals.dart` for the parsing half of the same rule.
String localizeDigits(String value, {required bool farsi}) =>
    numeralsFor(value, farsi: farsi);

extension StringExt on String {
  /// Converts ASCII digits to locale-specific digits.
  /// Farsi locale → Arabic-Indic digits (۰–۹); otherwise keeps ASCII digits.
  String localized(BuildContext context) => localizeDigits(
    this,
    farsi: Localizations.localeOf(context).languageCode == 'fa',
  );

  // Legacy: convert back to Latin digits (e.g. for sending over network)
  String toEnglish() => asciiNumerals(this);
}

extension IntExt on int {
  String localized(BuildContext context) => toString().localized(context);
}

extension DoubleExt on double {
  String localized(BuildContext context) => toString().localized(context);

  String localizedFixed(BuildContext context, int fractionDigits) =>
      toStringAsFixed(fractionDigits).localized(context);
}
