import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/motion/solid_sheet_route.dart';

/// Every opacity between [finder] and the root, multiplied out.
double _effectiveOpacity(WidgetTester tester, Finder finder) {
  var opacity = 1.0;
  for (final element in find
      .ancestor(of: finder, matching: find.byType(Opacity))
      .evaluate()) {
    opacity *= (element.widget as Opacity).opacity;
  }
  for (final element in find
      .ancestor(of: finder, matching: find.byType(FadeTransition))
      .evaluate()) {
    opacity *= (element.widget as FadeTransition).opacity.value;
  }
  return opacity;
}

/// The scale the screen below is drawn at.
double _belowScale(WidgetTester tester) {
  var scale = 1.0;
  for (final element in find
      .ancestor(of: find.text('below'), matching: find.byType(Transform))
      .evaluate()) {
    scale *= (element.widget as Transform).transform.entry(0, 0);
  }
  return scale;
}

Widget _app({bool reduced = false}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
    child: child!,
  ),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            SolidSheetRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('sheet'))),
            ),
          ),
          child: const Text('below'),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the sheet stays opaque while the screen below recedes', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('below'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_effectiveOpacity(tester, find.text('sheet')), 1);
    final midScale = _belowScale(tester);
    expect(midScale, lessThan(1));
    expect(midScale, greaterThan(SolidSheetRoute.recededScale - 0.001));
    await tester.pumpAndSettle();
    // Settled: the screen below is no longer painted at all.
    expect(find.text('below'), findsNothing);

    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (find.text('sheet').evaluate().isEmpty) break;
      // Never a crossfade: the leaving sheet is fully opaque at every frame,
      // and the screen below is drawn at full opacity behind it.
      expect(_effectiveOpacity(tester, find.text('sheet')), 1);
      expect(_effectiveOpacity(tester, find.text('below')), 1);
      expect(_belowScale(tester), lessThanOrEqualTo(1));
    }
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(_belowScale(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sheet travels vertically while leaving', (tester) async {
    await tester.pumpWidget(_app());
    await tester.tap(find.text('below'));
    await tester.pumpAndSettle();
    final rest = tester.getCenter(find.text('sheet'));
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final leaving = tester.getCenter(find.text('sheet'));
    expect(leaving.dx, rest.dx);
    expect(leaving.dy, greaterThan(rest.dy));
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion dips through the background, no travel', (
    tester,
  ) async {
    await tester.pumpWidget(_app(reduced: true));
    await tester.tap(find.text('below'));
    await tester.pumpAndSettle();
    final rest = tester.getCenter(find.text('sheet'));
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getCenter(find.text('sheet')), rest);
    expect(_belowScale(tester), 1);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page form keeps the page key and state across rebuilds', (
    tester,
  ) async {
    const page = SolidSheetPage<void>(
      key: ValueKey('p'),
      name: 'sheet',
      child: Scaffold(body: Text('page')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          pages: const [
            MaterialPage<void>(child: Scaffold(body: Text('below'))),
            page,
          ],
          onDidRemovePage: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('page'), findsOneWidget);
    expect(
      ModalRoute.of(tester.element(find.text('page')))!.settings,
      same(page),
    );
  });
}
