import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/qr_widgets.dart';

/// The bullet, the icon and the first line of text share one centre line,
/// whether the text runs to one line or wraps, in Persian or English.
void main() {
  Future<void> pump(
    WidgetTester tester,
    String text, {
    double scale = 1,
    double width = 360,
  }) => tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Localizations(
        locale: const Locale('en'),
        delegates: const [
          DefaultWidgetsLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
        ],
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: StepRow(index: 1, icon: Icons.touch_app_rounded, text: text),
          ),
        ),
      ),
    ),
  );

  double centreY(WidgetTester tester, Finder finder) =>
      tester.getRect(finder).center.dy;

  Finder bullet() => find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).shape == BoxShape.circle,
  );

  for (final text in [
    'اگه کد خواست، همینو اسکن کنه.',
    'If it asks for a code, scan this one.',
    'روی گوشی Sara، همین اتاق رو باز کنه و «شروع» رو بزنه. ' * 3,
    'On the other phone, open Tarkk, then scan this code. ' * 3,
  ]) {
    testWidgets(
      'icon sits on the bullet\'s centre: "${text.substring(0, 12)}"',
      (tester) async {
        await pump(tester, text);
        expect(
          centreY(tester, find.byType(Icon)),
          closeTo(centreY(tester, bullet()), 0.01),
        );
        // The text's first line is placed so its optical centre lands on the
        // same line.
        final textTop = tester.getTopLeft(find.byType(Text).last).dy;
        final rowTop = tester.getTopLeft(find.byType(StepRow)).dy;
        expect(
          textTop - rowTop + StepRow.opticalCentre(text, 12.5),
          closeTo(centreY(tester, bullet()) - rowTop, 0.01),
        );
      },
    );
  }

  test('Persian centres lower in its line than Latin', () {
    final fa = StepRow.opticalCentre('اسکن کن', 12.5);
    final en = StepRow.opticalCentre('scan it', 12.5);
    expect(fa, greaterThan(en));
    // Both inside the first 18.75 px line, below its middle-ish top half.
    expect(en, inInclusiveRange(8, 10));
    expect(fa, inInclusiveRange(9.5, 11));
  });

  testWidgets('large text moves the bullet and icon down to it', (
    tester,
  ) async {
    await pump(tester, 'If it asks for a code, scan this one.', scale: 2);
    final rowTop = tester.getTopLeft(find.byType(StepRow)).dy;
    final bulletCentre = centreY(tester, bullet()) - rowTop;
    expect(bulletCentre, greaterThan(12));
    expect(
      centreY(tester, find.byType(Icon)) - rowTop,
      closeTo(bulletCentre, 0.01),
    );
    final textTop = tester.getTopLeft(find.byType(Text).last).dy - rowTop;
    expect(textTop, closeTo(0, 0.01));
  });
}
