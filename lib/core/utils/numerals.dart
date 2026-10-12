/// The three sets of decimal digits a person in this app's audience can type.
///
/// * ASCII `0-9` — what every parser, file and wire format speaks.
/// * Extended Arabic-Indic `۰-۹` (U+06F0…) — Persian, what the Persian
///   keyboard on Android and iOS types, and what this app shows in Persian.
/// * Arabic-Indic `٠-٩` (U+0660…) — what an Arabic keyboard types. Persian
///   users meet it through pasted text and some third-party keyboards.
///
/// The rule the whole app follows: **display in the reader's digits, store and
/// parse in ASCII.** Everything that turns typed text into a number goes
/// through [asciiNumerals] (or [parseLocalizedInt] / [parseLocalizedDouble])
/// first, so a Persian `۱۲` and a Latin `12` can never parse differently, and
/// nothing persisted or sent between phones ever carries anything but ASCII
/// digits.
library;

const int _ascii0 = 0x30;
const int _persian0 = 0x06F0;
const int _arabic0 = 0x0660;

/// Arabic decimal separator `٫`, typed by Persian keyboards for a decimal
/// point.
const int _arabicDecimal = 0x066B;

/// Arabic thousands separator `٬`.
const int _arabicThousands = 0x066C;

/// The ASCII value (0–9) of [codeUnit] if it is a digit in any of the three
/// sets, otherwise null.
int? digitValue(int codeUnit) {
  if (codeUnit >= _ascii0 && codeUnit <= _ascii0 + 9) return codeUnit - _ascii0;
  if (codeUnit >= _persian0 && codeUnit <= _persian0 + 9) {
    return codeUnit - _persian0;
  }
  if (codeUnit >= _arabic0 && codeUnit <= _arabic0 + 9) {
    return codeUnit - _arabic0;
  }
  return null;
}

/// Whether [value] contains a digit from any of the three sets.
bool hasAnyDigit(String value) {
  for (final unit in value.codeUnits) {
    if (digitValue(unit) != null) return true;
  }
  return false;
}

String _mapDigits(String value, int zero) {
  // Every digit in all three sets is a single UTF-16 code unit, so this is a
  // one-for-one swap: the string keeps its length and every index in it —
  // which is what lets an input formatter keep the caret exactly where it was.
  List<int>? out;
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final digit = digitValue(units[i]);
    if (digit == null || units[i] == zero + digit) continue;
    out ??= List<int>.of(units);
    out[i] = zero + digit;
  }
  return out == null ? value : String.fromCharCodes(out);
}

/// [value] with every Persian or Arabic-Indic digit replaced by its ASCII
/// digit. Everything else — letters, spaces, punctuation — is left alone.
String asciiNumerals(String value) => _mapDigits(value, _ascii0);

/// [value] with every ASCII or Arabic-Indic digit replaced by its Persian
/// digit. Everything else is left alone.
String persianNumerals(String value) => _mapDigits(value, _persian0);

/// [value]'s digits in the digits of the app's current language: Persian when
/// [farsi], ASCII otherwise.
String numeralsFor(String value, {required bool farsi}) =>
    farsi ? persianNumerals(value) : asciiNumerals(value);

/// Parses an integer typed in any of the three digit sets.
///
/// Surrounding whitespace is ignored and the Arabic thousands separator `٬`
/// is dropped, as Persian keyboards insert it. Returns null for anything that
/// is not an integer — exactly like [int.tryParse] on the ASCII text.
int? parseLocalizedInt(String raw) =>
    int.tryParse(_normalizeNumber(raw, decimal: false));

/// Parses a decimal number typed in any of the three digit sets.
///
/// Accepts the Arabic decimal separator `٫` as well as `.`; otherwise like
/// [double.tryParse] on the ASCII text.
double? parseLocalizedDouble(String raw) =>
    double.tryParse(_normalizeNumber(raw, decimal: true));

String _normalizeNumber(String raw, {required bool decimal}) {
  final out = StringBuffer();
  for (final unit in asciiNumerals(raw.trim()).codeUnits) {
    if (unit == _arabicThousands) continue;
    if (unit == _arabicDecimal) {
      // Left in place for an integer, so it fails to parse as one instead of
      // silently turning `۱٫۵` into 15.
      out.writeCharCode(decimal ? 0x2E : unit);
      continue;
    }
    out.writeCharCode(unit);
  }
  return out.toString();
}
