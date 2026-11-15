import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/monogram_mark.dart';
import 'package:tark/feature/room/domain/service/room_topic_matcher.dart';
import 'package:tark/feature/room/presentation/widget/room_topic_icon.dart';

Widget _host(Widget child, {bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  setUp(RoomTopicMatcher.clearCache);

  test('a name reads as its topic icon, or none', () {
    expect(roomIconFor('کوهنوردی جمعه'), Icons.hiking_rounded);
    expect(roomIconFor("Pedram's Road Trip"), Icons.directions_car_rounded);
    expect(roomIconFor('اکیپ پدرام'), Icons.groups_rounded);
    expect(roomIconFor('خانواده'), Icons.family_restroom_rounded);
    expect(roomIconFor('XQZ'), isNull);
  });

  test('topics that mean different things look different', () {
    // Pets and wild animals share the paw; every other topic has its own
    // glyph, so two Rooms about different things never look alike.
    final shared = {RoomTopic.pets, RoomTopic.animals};
    final icons = [
      for (final topic in RoomTopic.values)
        if (!shared.contains(topic)) topic.icon,
    ];
    expect(icons.toSet().length, icons.length);
  });

  group('MonogramMark', () {
    testWidgets('wears the topic icon in place of the letter', (tester) async {
      await tester.pumpWidget(
        _host(
          MonogramMark(
            name: 'Hiking',
            accent: Colors.amber,
            icon: roomIconFor('Hiking'),
          ),
        ),
      );
      expect(find.byIcon(Icons.hiking_rounded), findsOneWidget);
      expect(find.text('H'), findsNothing);
    });

    testWidgets('keeps the letter when the name says nothing', (tester) async {
      await tester.pumpWidget(
        _host(
          MonogramMark(
            name: 'Zephyr',
            accent: Colors.amber,
            icon: roomIconFor('Zephyr'),
          ),
        ),
      );
      expect(find.text('Z'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('an archived Room keeps its box over the topic', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          MonogramMark(
            name: 'Hiking',
            accent: Colors.amber,
            icon: roomIconFor('Hiking'),
            child: const Icon(Icons.archive_rounded),
          ),
        ),
      );
      expect(find.byIcon(Icons.archive_rounded), findsOneWidget);
      expect(find.byIcon(Icons.hiking_rounded), findsNothing);
    });

    testWidgets('a rename springs the new icon in over the letter', (
      tester,
    ) async {
      Widget mark(String name) => _host(
        MonogramMark(name: name, accent: Colors.amber, icon: roomIconFor(name)),
      );
      await tester.pumpWidget(mark('Zephyr'));
      await tester.pumpWidget(mark('Ski trip'));
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-flight both are on screen: the letter leaving, the icon arriving.
      expect(find.text('Z'), findsOneWidget);
      expect(find.byIcon(Icons.downhill_skiing_rounded), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Z'), findsNothing);
      expect(find.byIcon(Icons.downhill_skiing_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('RoomTopicGlyph', () {
    testWidgets('follows the name as it changes', (tester) async {
      final name = ValueNotifier('کوه');
      addTearDown(name.dispose);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder(
            valueListenable: name,
            builder: (_, value, _) => RoomTopicGlyph(
              name: value,
              color: Colors.amber,
              fallback: roomFallbackIcon,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.hiking_rounded), findsOneWidget);

      name.value = 'کوهنوردی و کمپینگ';
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.hiking_rounded), findsOneWidget);

      name.value = 'جوجه کباب';
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.outdoor_grill_rounded), findsOneWidget);
      expect(find.byIcon(Icons.hiking_rounded), findsNothing);

      name.value = 'XQZ';
      await tester.pumpAndSettle();
      expect(find.byIcon(roomFallbackIcon), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('folds away when there is no topic and no fallback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const RoomTopicGlyph(name: 'XQZ', color: Colors.amber, gap: 6)),
      );
      expect(find.byType(Icon), findsNothing);
      expect(tester.getSize(find.byType(RoomTopicGlyph)).width, 0);
    });

    testWidgets('under reduced motion the icon swaps at once', (tester) async {
      Widget glyph(String name) =>
          _host(RoomTopicGlyph(name: name, color: Colors.amber), reduced: true);
      await tester.pumpWidget(glyph('Football'));
      await tester.pumpWidget(glyph('Basketball'));
      await tester.pump();
      expect(find.byIcon(Icons.sports_soccer_rounded), findsNothing);
      expect(find.byIcon(Icons.sports_basketball_rounded), findsOneWidget);
    });

    testWidgets('is not read out: the name already says it', (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const RoomTopicGlyph(name: 'Football', color: Colors.amber)),
      );
      expect(tester.getSemantics(find.byType(RoomTopicGlyph)).label, isEmpty);
      semantics.dispose();
    });
  });
}
