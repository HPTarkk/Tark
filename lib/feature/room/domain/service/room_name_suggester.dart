import 'dart:math';

import '../../../../core/utils/numerals.dart';

/// Ready-made Room names, so creating a Room never starts at an empty field.
///
/// Names are built around the creator's own name ("Pedram's Crew",
/// «اکیپ پدرام»), since that's how people actually name a group they
/// start. The curated names below are only used when there is no name to
/// build on yet.
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

  static const _ownedEn = [
    "{name}'s Crew",
    "{name}'s Squad",
    "{name}'s Convoy",
    "{name}'s Pack",
    'Team {name}',
    "{name}'s Riders",
    "{name}'s Road Trip",
    '{name} & Co.',
    "{name}'s Night Ride",
    "{name}'s Gang",
  ];

  static const _ownedFa = [
    'اکیپ {name}',
    'گروه {name}',
    'کاروان {name}',
    'یاران {name}',
    'تیم {name}',
    'رفقای {name}',
    'سفر {name}',
    'هم‌سفرهای {name}',
    'دورهمی {name}',
    'دار و دستهٔ {name}',
  ];

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

  /// Every name this language can suggest for [ownerName], or the curated
  /// names when there is no name to build on. Exposed for tests.
  static List<String> namesFor(String languageCode, {String? ownerName}) {
    final owner = ownerName?.trim() ?? '';
    if (owner.isEmpty) return languageCode == 'fa' ? _fa : _en;
    final templates = languageCode == 'fa' ? _ownedFa : _ownedEn;
    return [for (final t in templates) t.replaceAll('{name}', owner)];
  }

  /// A name in [languageCode], built on [ownerName] when there is one, that
  /// is not in [taken] and is not [previous],
  /// so shuffling always visibly changes the field.
  ///
  /// When every curated name is already in use, a number is added to one
  /// instead of returning a duplicate. The digits follow the language, so a
  /// Persian name gets Persian digits.
  String suggest(
    String languageCode, {
    String? ownerName,
    Iterable<String> taken = const [],
    String? previous,
  }) {
    final used = {for (final name in taken) _fold(name)};
    if (previous != null) used.add(_fold(previous));
    final names = namesFor(languageCode, ownerName: ownerName);
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
