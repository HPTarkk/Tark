import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/announcement/domain/entity/announcement.dart';

/// Guards the hand-edited `website/announcements.json`: every entry in it
/// must be one the app will actually show, or this fails naming it.
void main() {
  test(
    'website/announcements.json is a valid feed with no skipped entries',
    () {
      final file = File('website/announcements.json');
      expect(file.existsSync(), isTrue);
      final json = jsonDecode(file.readAsStringSync());
      expect(json, isA<Map<String, dynamic>>());
      final feed = AnnouncementFeed.fromJson(json as Map<String, dynamic>);
      expect(feed.rejected, isEmpty, reason: feed.rejected.join('\n'));
      // A Persian text should exist wherever an English one does: most riders
      // read the app in Persian.
      for (final a in feed.announcements) {
        for (final (name, text) in [
          ('title', a.title),
          ('body', a.body),
          ('highlight', a.highlight),
          ('action.label', a.action?.label ?? const LocalizedText({})),
        ]) {
          if (text.isEmpty) continue;
          expect(
            text.byLanguage.keys,
            containsAll(['en', 'fa']),
            reason: '"${a.id}": $name needs both en and fa',
          );
        }
      }
    },
  );
}
