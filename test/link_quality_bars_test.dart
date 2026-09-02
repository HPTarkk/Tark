import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  /// Bars the meter actually paints at full opacity — the lit ones. Unlit bars
  /// are drawn too, as a track, which is why counting boxes is not enough.
  int litBars(WidgetTester tester) {
    final containers = tester.widgetList<Container>(
      find.descendant(
        of: find.byType(LinkQualityBars),
        matching: find.byType(Container),
      ),
    );
    return containers.where((c) {
      final decoration = c.decoration;
      if (decoration is! BoxDecoration) return false;
      return (decoration.color?.a ?? 0) > 0.5;
    }).length;
  }

  Future<void> pumpMeter(WidgetTester tester, LinkQuality quality) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LinkQualityBars(
              filled: LinkQualityBars.barsFor(quality),
              color: const Color(0xFF4CAF50),
            ),
          ),
        ),
      ),
    );
  }

  group('LinkQualityBars', () {
    test('a full meter means nothing at all is wrong', () {
      expect(LinkQualityBars.barsFor(LinkQuality.excellent), 4);
      expect(LinkQualityBars.barsFor(LinkQuality.good), 3);
      expect(LinkQualityBars.barsFor(LinkQuality.weak), 2);
      expect(LinkQualityBars.barsFor(LinkQuality.recovering), 1);
      // Nobody on the channel lights nothing. The meter is a measurement of a
      // link, and there is no link to measure.
      expect(LinkQualityBars.barsFor(LinkQuality.alone), 0);
    });

    testWidgets('each grade lights its own number of bars', (tester) async {
      for (final (quality, expected) in [
        (LinkQuality.excellent, 4),
        (LinkQuality.good, 3),
        (LinkQuality.weak, 2),
        (LinkQuality.recovering, 1),
      ]) {
        await pumpMeter(tester, quality);
        expect(litBars(tester), expected, reason: quality.name);
      }
    });

    testWidgets('the unlit track is always drawn, so the meter reads as one', (
      tester,
    ) async {
      await pumpMeter(tester, LinkQuality.recovering);
      final all = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(LinkQualityBars),
          matching: find.byType(Container),
        ),
      );
      // One lit, three tracks — never a single bar floating on its own.
      expect(all, hasLength(4));
      expect(litBars(tester), 1);
    });

    testWidgets('an inactive session shows an empty meter, not a grade', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: LinkQualityBars(filled: 0, color: const Color(0xFF9E9E9E)),
            ),
          ),
        ),
      );
      expect(litBars(tester), 0);
    });
  });
}
