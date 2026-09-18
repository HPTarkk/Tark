import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/ticker_text.dart';

/// Reproduces the mic card's layout: a Row whose middle column is Expanded,
/// with the label ticking inside it. The bug only shows up under a real
/// parent, since it is about how wide the ticker makes itself.
Widget _host(
  String text, {
  TextAlign? align,
  TextDirection direction = TextDirection.ltr,
}) => MaterialApp(
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Row(
        children: [
          const SizedBox(width: 42, height: 42),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TickerText(
                  text: text,
                  textAlign: align,
                  maxLines: 1,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
          const SizedBox(width: 60),
        ],
      ),
    ),
  ),
);

/// Samples where the incoming line sits across the swap, then compares each
/// sample to where it finally settles. Any difference is the visible jump.
Future<void> _expectNoHorizontalJump(
  WidgetTester tester, {
  required String from,
  required String to,
  required TextDirection direction,
}) async {
  await tester.pumpWidget(_host(from, direction: direction));
  await tester.pumpAndSettle();

  await tester.pumpWidget(_host(to, direction: direction));
  await tester.pump(); // kick the controller

  final positions = <double>[];
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(to), findsOneWidget);
    positions.add(tester.getTopLeft(find.text(to)).dx);
  }

  await tester.pumpAndSettle();
  final settled = tester.getTopLeft(find.text(to)).dx;

  for (final (i, x) in positions.indexed) {
    expect(
      x,
      moreOrLessEquals(settled, epsilon: 0.5),
      reason:
          '$direction sample $i sat at $x but settles at $settled — the text '
          'moves horizontally during the swap and snaps at the end',
    );
  }
}

void main() {
  testWidgets('LTR: long to short does not shift horizontally', (tester) async {
    await _expectNoHorizontalJump(
      tester,
      from: 'Everyone hears you',
      to: 'No one hears you',
      direction: TextDirection.ltr,
    );
  });

  // The reported bug. Two things have to line up for it to show:
  //   * RTL, so the parent start-aligns the box to the RIGHT, and
  //   * the incoming line is SHORTER, so the box actually shrinks at the end.
  // With equal-length strings, or a line that grows, the box never narrows and
  // nothing moves — which is why an earlier version of this test passed
  // against the broken alignment. In flutter_test every glyph is a fixed-width
  // box, so "shorter" here means fewer characters.
  testWidgets('RTL: long to short does not shift horizontally', (tester) async {
    const long = 'میکروفن روشنه'; // MIC LIVE  (13)
    const short = 'ساکتی'; //          MUTED     (5)
    expect(short.length, lessThan(long.length), reason: 'box must shrink');

    await _expectNoHorizontalJump(
      tester,
      from: long,
      to: short,
      direction: TextDirection.rtl,
    );
  });

  testWidgets('RTL: subtitle long to short does not shift', (tester) async {
    await _expectNoHorizontalJump(
      tester,
      from: 'همه صدایت را می‌شنوند',
      to: 'کسی نمی‌شنود',
      direction: TextDirection.rtl,
    );
  });

  testWidgets('incoming text keeps its left edge fixed for the whole swap', (
    tester,
  ) async {
    // Long -> short is the case that matters: while both are on screen the
    // ticker is as wide as the LONGER one, and if the incoming text is
    // positioned against that wider box it sits somewhere other than where it
    // will finally land.
    await tester.pumpWidget(_host('Everyone hears you'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host('No one hears you'));
    await tester.pump(); // kick the controller

    // Sample the incoming text's position across the transition.
    final positions = <double>[];
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final incoming = find.text('No one hears you');
      expect(incoming, findsOneWidget);
      positions.add(tester.getTopLeft(incoming).dx);
    }

    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.text('No one hears you')).dx;

    for (final (i, x) in positions.indexed) {
      expect(
        x,
        moreOrLessEquals(settled, epsilon: 0.5),
        reason:
            'sample $i sat at $x but settles at $settled — the text moves '
            'horizontally during the swap and snaps at the end',
      );
    }
  });

  testWidgets('outgoing text also holds its left edge', (tester) async {
    await tester.pumpWidget(_host('MUTED'));
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('MUTED')).dx;

    await tester.pumpWidget(_host('MIC LIVE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(
      tester.getTopLeft(find.text('MUTED')).dx,
      moreOrLessEquals(before, epsilon: 0.5),
      reason: 'the outgoing line should slide out vertically, not sideways',
    );
  });
}
