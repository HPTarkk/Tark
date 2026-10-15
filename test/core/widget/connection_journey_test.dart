import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/connection_journey.dart';

/// Every link plays every stage, and every hand-off between them, without
/// throwing — with motion, without it, and right to left.
void main() {
  Widget scene(
    JourneyStage stage,
    JourneyLink link, {
    bool reduced = false,
    bool rtl = false,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(412, 915),
        disableAnimations: reduced,
      ),
      child: Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: ConnectionJourney(
            key: const ValueKey('journey'),
            stage: stage,
            link: link,
            title: stage.name,
            detail: link.name,
          ),
        ),
      ),
    ),
  );

  for (final link in JourneyLink.values) {
    for (final (reduced, rtl) in [
      (false, false),
      (false, true),
      (true, false),
    ]) {
      testWidgets('${link.name} links, then locks, then snaps '
          '(reduced: $reduced, rtl: $rtl)', (tester) async {
        for (final stage in [
          JourneyStage.scanned,
          JourneyStage.linking,
          JourneyStage.established,
          JourneyStage.failed,
          JourneyStage.linking,
          JourneyStage.failed,
        ]) {
          await tester.pumpWidget(
            scene(stage, link, reduced: reduced, rtl: rtl),
          );
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.text(stage.name), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('${link.name} can open straight into a failure', (
      tester,
    ) async {
      await tester.pumpWidget(scene(JourneyStage.failed, link));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
