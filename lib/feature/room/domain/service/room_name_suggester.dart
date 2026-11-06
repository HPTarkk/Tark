import 'dart:math';

import '../../../../core/utils/numerals.dart';

/// Ready-made Room names, so creating a Room never starts at an empty field.
///
/// Inventing a name is the one step in creation that makes people stop and
/// think, and almost nobody cares what the name is as long as it is not
/// "Room 1". So creation always starts with a name already in the field.
/// It can be kept with one tap, changed by typing, or swapped for another
/// with the shuffle button.
///
/// Curated whole names rather than random adjective + noun pairs: random pairs
/// produce duds ("Polite Gravel") and, in Persian, often get the word order
/// or the plural wrong.
class RoomNameSuggester {
  RoomNameSuggester({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const _en = [
    'Night Owls',
    'Desert Wolves',
    'Thunder Crew',
    'Iron Riders',
    'Wild Comets',
    'Midnight Convoy',
    'Silver Foxes',
    'Storm Chasers',
    'Red Falcons',
    'Dust Devils',
    'Northern Lights',
    'Echo Squad',
    'Rolling Thunder',
    'Neon Tigers',
    'Mountain Goats',
    'Road Runners',
    'Sky Pirates',
    'Wolf Pack',
    'Crimson Arrows',
    'Star Hoppers',
    'Copper Bears',
    'Sunset Riders',
    'Snow Leopards',
    'Lucky Sevens',
  ];

  static const _fa = [
    'گرگ‌های کویر',
    'جغدهای شب',
    'اکیپ رعد',
    'سواران آهنین',
    'شاهین‌های سرخ',
    'کاروان نیمه‌شب',
    'روباه‌های نقره‌ای',
    'طوفان‌گردها',
    'ببرهای نئونی',
    'شب‌گردها',
    'ستاره‌های دنباله‌دار',
    'عقاب‌های کوهستان',
    'شیرهای جاده',
    'یاران سفر',
    'اکیپ پژواک',
    'سایه‌های شب',
    'پلنگ‌های برفی',
    'گردبادها',
    'کاروان ستاره',
    'دلاوران دشت',
    'اکیپ آتش',
    'رهروان باد',
    'سواران غروب',
    'خرس‌های قطبی',
  ];

  /// Every name this language can suggest. Exposed for tests.
  static List<String> namesFor(String languageCode) =>
      languageCode == 'fa' ? _fa : _en;

  /// A name in [languageCode] that is not in [taken] and is not [previous],
  /// so shuffling always visibly changes the field.
  ///
  /// When every curated name is already in use, a number is added to one
  /// instead of returning a duplicate. The digits follow the language, so a
  /// Persian name gets Persian digits.
  String suggest(
    String languageCode, {
    Iterable<String> taken = const [],
    String? previous,
  }) {
    final used = {for (final name in taken) _fold(name)};
    if (previous != null) used.add(_fold(previous));
    final names = namesFor(languageCode);
    final free = [
      for (final name in names)
        if (!used.contains(_fold(name))) name,
    ];
    if (free.isNotEmpty) return free[_random.nextInt(free.length)];
    final base = names[_random.nextInt(names.length)];
    for (var n = 2; ; n++) {
      final candidate = numeralsFor('$base $n', farsi: languageCode == 'fa');
      if (!used.contains(_fold(candidate))) return candidate;
    }
  }

  static String _fold(String name) => name.trim().toLowerCase();
}
