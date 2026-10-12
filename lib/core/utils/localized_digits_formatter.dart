import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'numerals.dart';

/// Shows whatever digits are typed into a text field in the digits of the
/// app's language.
///
/// The keyboard decides what reaches a field, not the app: Gboard and
/// SwiftKey type Latin `2` on a Persian layout's number row, the Persian
/// keyboard types `۲`, and a paste can carry either. Without this a Persian
/// screen showed «سفر 2» — the most visible way an app can look half
/// translated. With it, every digit is swapped one-for-one as it is typed:
/// Persian digits in Persian, Latin in English.
///
/// **What this is for:** text a person reads back — room names, display
/// names, callsigns. **What it must never touch:** identifiers and secrets —
/// passwords, addresses, codes pasted from another phone — which keep exactly
/// what was typed. Numeric fields that feed a parser keep their controller in
/// ASCII instead (see [anyDigitsOnly] and `asciiNumerals`), and localize only
/// when drawing.
///
/// The swap is length-preserving (every digit in every set is one UTF-16 code
/// unit), so the caret and selection stay exactly where they were. The span
/// the keyboard is still composing is left alone until it is committed:
/// rewriting text under an active IME composition makes some keyboards
/// duplicate it.
class LocaleDigitsFormatter extends TextInputFormatter {
  const LocaleDigitsFormatter({required this.farsi});

  /// The formatter for the app's current language at [context].
  factory LocaleDigitsFormatter.of(BuildContext context) =>
      LocaleDigitsFormatter(
        farsi: Localizations.localeOf(context).languageCode == 'fa',
      );

  /// Persian digits when true, Latin digits otherwise.
  final bool farsi;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!hasAnyDigit(text)) return newValue;
    final composing = newValue.composing;
    final String mapped;
    if (composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= text.length) {
      mapped =
          numeralsFor(composing.textBefore(text), farsi: farsi) +
          composing.textInside(text) +
          numeralsFor(composing.textAfter(text), farsi: farsi);
    } else {
      mapped = numeralsFor(text, farsi: farsi);
    }
    if (mapped == text) return newValue;
    return newValue.copyWith(text: mapped);
  }
}

/// Digits only — in any of the three digit sets.
///
/// The drop-in replacement for [FilteringTextInputFormatter.digitsOnly], which
/// allows ASCII `0-9` alone and so silently swallowed every key a Persian
/// keyboard's number row sends. Pair it with `asciiNumerals` (or
/// `parseLocalizedInt`) where the text is read.
final TextInputFormatter anyDigitsOnly = FilteringTextInputFormatter.allow(
  RegExp('[0-9۰-۹٠-٩]'),
);
