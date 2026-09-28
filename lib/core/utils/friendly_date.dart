import 'package:flutter/widgets.dart';

import 'extensions.dart';

/// A calendar date written the way a person would say it: "12 October 2026"
/// in English, "۲۰ مهر ۱۴۰۵" in Persian. Persian uses the Solar Hijri
/// calendar because that is the one Iranian readers actually live by — a
/// Gregorian date with Persian month names is technically translated and
/// practically unreadable.
///
/// Shown in the phone's local time zone: "ended on the 12th" should match the
/// day the reader remembers, not the day in UTC.
abstract final class FriendlyDate {
  static String format(BuildContext context, DateTime instant) {
    final farsi = Localizations.localeOf(context).languageCode == 'fa';
    return formatFor(instant.toLocal(), farsi: farsi);
  }

  static String formatFor(DateTime local, {required bool farsi}) {
    if (!farsi) {
      return '${local.day} ${_gregorianMonths[local.month - 1]} ${local.year}';
    }
    final (y, m, d) = toJalali(local.year, local.month, local.day);
    return localizeDigits('$d ${_jalaliMonths[m - 1]} $y', farsi: true);
  }

  /// Gregorian → Solar Hijri, (year, month, day). The standard arithmetic
  /// conversion (as used by jdf and most Iranian software), valid far beyond
  /// any date this app will ever show.
  static (int, int, int) toJalali(int gy, int gm, int gd) {
    const monthOffsets = [
      0,
      31,
      59,
      90,
      120,
      151,
      181,
      212,
      243,
      273,
      304,
      334,
    ];
    final gy2 = gm > 2 ? gy + 1 : gy;
    var days =
        355666 +
        365 * gy +
        (gy2 + 3) ~/ 4 -
        (gy2 + 99) ~/ 100 +
        (gy2 + 399) ~/ 400 +
        gd +
        monthOffsets[gm - 1];
    var jy = -1595 + 33 * (days ~/ 12053);
    days %= 12053;
    jy += 4 * (days ~/ 1461);
    days %= 1461;
    if (days > 365) {
      jy += (days - 1) ~/ 365;
      days = (days - 1) % 365;
    }
    final int jm;
    final int jd;
    if (days < 186) {
      jm = 1 + days ~/ 31;
      jd = 1 + days % 31;
    } else {
      jm = 7 + (days - 186) ~/ 30;
      jd = 1 + (days - 186) % 30;
    }
    return (jy, jm, jd);
  }

  static const _gregorianMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  static const _jalaliMonths = [
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند',
  ];
}
