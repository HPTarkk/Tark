import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/utils/friendly_date.dart';

void main() {
  group('Solar Hijri conversion', () {
    test('known dates', () {
      // Nowruz 1403 and 1404.
      expect(FriendlyDate.toJalali(2024, 3, 20), (1403, 1, 1));
      expect(FriendlyDate.toJalali(2025, 3, 21), (1404, 1, 1));
      // Last day of a leap year (1403 has 30 Esfand).
      expect(FriendlyDate.toJalali(2025, 3, 20), (1403, 12, 30));
      // Yalda night.
      expect(FriendlyDate.toJalali(2025, 12, 21), (1404, 9, 30));
      expect(FriendlyDate.toJalali(2026, 9, 28), (1405, 7, 6));
    });
  });

  test('formats in each language', () {
    final date = DateTime(2026, 10, 12);
    expect(FriendlyDate.formatFor(date, farsi: false), '12 October 2026');
    expect(FriendlyDate.formatFor(date, farsi: true), '۲۰ مهر ۱۴۰۵');
  });
}
