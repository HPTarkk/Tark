import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/account/auth_repository.dart';
import 'package:tark/core/utils/extensions.dart';
import 'package:tark/core/utils/numerals.dart';

void main() {
  group('asciiNumerals', () {
    test('folds Persian and Arabic-Indic digits to ASCII', () {
      expect(asciiNumerals('۰۱۲۳۴۵۶۷۸۹'), '0123456789');
      expect(asciiNumerals('٠١٢٣٤٥٦٧٨٩'), '0123456789');
      expect(asciiNumerals('0123456789'), '0123456789');
    });

    test('leaves everything that is not a digit alone', () {
      expect(asciiNumerals('سفر ۲ - Ride ٣!'), 'سفر 2 - Ride 3!');
      expect(asciiNumerals(''), '');
      expect(asciiNumerals('بدون عدد'), 'بدون عدد');
    });

    test('returns the same instance when there is nothing to change', () {
      const value = 'Ride 42';
      expect(identical(asciiNumerals(value), value), isTrue);
    });
  });

  group('persianNumerals / numeralsFor', () {
    test('show ASCII and Arabic-Indic digits as Persian', () {
      expect(persianNumerals('Ride 2 ٣'), 'Ride ۲ ۳');
    });

    test('pick the digits of the language', () {
      expect(numeralsFor('سفر 2 ٣ ۴', farsi: true), 'سفر ۲ ۳ ۴');
      expect(numeralsFor('سفر 2 ٣ ۴', farsi: false), 'سفر 2 3 4');
    });

    test('never change the length, so indexes into the text survive', () {
      const mixed = 'a1۲٣b';
      expect(persianNumerals(mixed).length, mixed.length);
      expect(asciiNumerals(mixed).length, mixed.length);
    });
  });

  group('parseLocalizedInt', () {
    test('parses every digit set to the same value', () {
      expect(parseLocalizedInt('12'), 12);
      expect(parseLocalizedInt('۱۲'), 12);
      expect(parseLocalizedInt('١٢'), 12);
      expect(parseLocalizedInt('۱2'), 12);
    });

    test('trims, signs and drops the Persian thousands separator', () {
      expect(parseLocalizedInt('  ۴۲ '), 42);
      expect(parseLocalizedInt('-۷'), -7);
      expect(parseLocalizedInt('۱٬۲۰۰'), 1200);
    });

    test('rejects what int.tryParse rejects', () {
      expect(parseLocalizedInt(''), isNull);
      expect(parseLocalizedInt('۱۲a'), isNull);
      expect(parseLocalizedInt('سفر'), isNull);
      // A decimal is not silently read as a larger integer.
      expect(parseLocalizedInt('۱٫۵'), isNull);
      expect(parseLocalizedInt('1.5'), isNull);
    });
  });

  group('parseLocalizedDouble', () {
    test('accepts both decimal separators and every digit set', () {
      expect(parseLocalizedDouble('۱٫۵'), 1.5);
      expect(parseLocalizedDouble('١.٢٥'), 1.25);
      expect(parseLocalizedDouble('3.5'), 3.5);
      expect(parseLocalizedDouble('۲'), 2);
    });

    test('rejects what double.tryParse rejects', () {
      expect(parseLocalizedDouble(''), isNull);
      expect(parseLocalizedDouble('۱٫۲٫۳'), isNull);
    });
  });

  test('digitValue knows exactly the thirty digits', () {
    expect(digitValue('7'.codeUnitAt(0)), 7);
    expect(digitValue('۷'.codeUnitAt(0)), 7);
    expect(digitValue('٧'.codeUnitAt(0)), 7);
    expect(digitValue('a'.codeUnitAt(0)), isNull);
    expect(digitValue('/'.codeUnitAt(0)), isNull);
    expect(digitValue(':'.codeUnitAt(0)), isNull);
  });

  test('existing helpers agree with the shared rule', () {
    expect(localizeDigits('5/48', farsi: true), '۵/۴۸');
    expect(localizeDigits('۵/۴۸', farsi: false), '5/48');
    // Arabic-Indic now reads in the language's digits as well.
    expect(localizeDigits('٥', farsi: true), '۵');
    expect(localizeDigits('٥', farsi: false), '5');
    expect('۱۲'.toEnglish(), '12');
    // The account code path still produces the server's ASCII six digits.
    expect(asciiDigits('۱۲-۳٤ 56'), '123456');
  });
}
