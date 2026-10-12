import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/link_preparing_visual.dart';

void main() {
  const readyKey = Key('the-real-code');
  const code = SizedBox(key: readyKey, width: 100, height: 100);

  Widget host({
    Widget? ready,
    LinkPreparingKind kind = LinkPreparingKind.hotspot,
    bool reduced = false,
  }) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinkPreparingVisual(kind: kind, qrSize: 200, ready: ready),
              LinkPreparingCaption(kind: kind),
            ],
          ),
        ),
      ),
    ),
  );

  Finder painter() => find.descendant(
    of: find.byType(LinkPreparingVisual),
    matching: find.byType(CustomPaint),
  );

  testWidgets('takes exactly the footprint of the code it becomes', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    expect(
      tester.getSize(find.byType(LinkPreparingVisual)),
      const Size.square(254),
    );
    expect(LinkPreparingVisual.extentFor(200), 254);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('beacons while preparing, then resolves into the code and '
      'stops ticking', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 3));
    expect(painter(), findsWidgets);
    expect(find.byKey(readyKey), findsNothing);
    // The beacon is alive.
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(host(ready: code));
    await tester.pump(const Duration(milliseconds: 520));
    // Mid hand-over: both are on screen, the code still faint.
    expect(find.byKey(readyKey), findsOneWidget);
    final mid = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(readyKey), matching: find.byType(Opacity)),
    );
    expect(mid.opacity, lessThan(1));

    await tester.pumpAndSettle();
    expect(find.byKey(readyKey), findsOneWidget);
    final done = tester.widget<Opacity>(
      find
          .ancestor(of: find.byKey(readyKey), matching: find.byType(Opacity))
          .first,
    );
    expect(done.opacity, 1);
    // pumpAndSettle returning at all means the clock stopped.
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('losing the code again plays the morph back to the beacon', (
    tester,
  ) async {
    await tester.pumpWidget(host(ready: code));
    await tester.pumpAndSettle();
    expect(find.byKey(readyKey), findsOneWidget);

    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(readyKey), findsNothing);
    expect(painter(), findsWidgets);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion draws a still frame and crossfades', (
    tester,
  ) async {
    await tester.pumpWidget(host(reduced: true));
    await tester.pump();
    expect(painter(), findsWidgets);
    // Nothing loops.
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(host(reduced: true, ready: code));
    await tester.pumpAndSettle();
    expect(find.byKey(readyKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('captions say which link is coming up', (tester) async {
    await tester.pumpWidget(host(kind: LinkPreparingKind.bluetooth));
    expect(find.textContaining('Bluetooth is waking up'), findsOneWidget);
    await tester.pumpWidget(host());
    expect(find.textContaining('becoming a hotspot'), findsOneWidget);
    await tester.pumpWidget(host(kind: LinkPreparingKind.code));
    expect(find.text('Signing your invite code.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disposes mid-beacon and mid-hand-over without leaking', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(host(ready: code));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
