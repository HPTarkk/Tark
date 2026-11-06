import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/service/room_name_suggester.dart';

void main() {
  for (final language in ['en', 'fa']) {
    group(language, () {
      final names = RoomNameSuggester.namesFor(language);

      test('suggests one of the curated names', () {
        final suggester = RoomNameSuggester(random: Random(1));
        for (var i = 0; i < 50; i++) {
          expect(names, contains(suggester.suggest(language)));
        }
      });

      test('never repeats a name already in use, or the previous one', () {
        final suggester = RoomNameSuggester(random: Random(2));
        final taken = names.take(names.length - 2).toList();
        final previous = names[names.length - 2];
        for (var i = 0; i < 20; i++) {
          expect(
            suggester.suggest(language, taken: taken, previous: previous),
            names.last,
          );
        }
      });

      test('numbers a name once every curated one is taken', () {
        final suggester = RoomNameSuggester(random: Random(3));
        final name = suggester.suggest(language, taken: names);
        expect(names, isNot(contains(name)));
        expect(name, endsWith(language == 'fa' ? ' ۲' : ' 2'));
      });

      test('names are unique and fit the 48-character field', () {
        expect(names.toSet().length, names.length);
        for (final name in names) {
          expect(name.length, lessThanOrEqualTo(40));
        }
      });
    });
  }

  test('taken names match regardless of case and spacing', () {
    final names = RoomNameSuggester.namesFor('en');
    final suggester = RoomNameSuggester(random: Random(4));
    final taken = [
      for (final name in names.skip(1)) '  ${name.toUpperCase()} ',
    ];
    expect(suggester.suggest('en', taken: taken), names.first);
  });
}
