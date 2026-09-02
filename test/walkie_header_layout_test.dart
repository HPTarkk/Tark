import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/widget/settings_icon_button.dart';
import 'package:tark/feature/walkie/presentation/widget/walkie_header.dart';

void main() {
  group('WalkieHeaderLayout', () {
    test('keeps decorative title out of the 320px Ride Mode header', () {
      expect(WalkieHeaderLayout.showAppTitle(320), isFalse);
      expect(WalkieHeaderLayout.showAppTitle(389), isFalse);
    });

    test('restores the app title when the header has spare width', () {
      expect(WalkieHeaderLayout.showAppTitle(390), isTrue);
      expect(WalkieHeaderLayout.showAppTitle(480), isTrue);
    });

    test('lands every row on the body column, whatever the control is', () {
      // A bare identity line owns no padding, so it sits on the margin.
      expect(WalkieHeaderLayout.inset(0), WalkieHeaderLayout.opticalMargin);

      // The compensated insets: what the bar pads, plus what the control
      // already carries, is the margin in every case.
      for (final controlInset in [
        WalkieHeaderLayout.iconButtonInset,
        WalkieHeaderLayout.settingsChipInset,
      ]) {
        expect(
          WalkieHeaderLayout.inset(controlInset) + controlInset,
          WalkieHeaderLayout.opticalMargin,
          reason:
              'a control carrying $controlInset must still draw its edge '
              'on the ${WalkieHeaderLayout.opticalMargin} column',
        );
      }

      // The regression this replaces: an IconButton row and a chip row given
      // the same number end up 4 apart on screen.
      expect(
        WalkieHeaderLayout.inset(WalkieHeaderLayout.iconButtonInset),
        isNot(WalkieHeaderLayout.inset(WalkieHeaderLayout.settingsChipInset)),
      );
    });

    test('never pushes a row past the margin for an over-padded control', () {
      expect(WalkieHeaderLayout.inset(40), 0);
      expect(WalkieHeaderLayout.inset(WalkieHeaderLayout.opticalMargin), 0);
    });
  });

  // The arithmetic above is only correct if the two controls really do carry
  // the padding it claims. These measure them against Flutter's own layout,
  // because both numbers are inherited rather than declared: `IconButton`'s
  // comes from the Material theme, and the settings chip's from a wrapper that
  // squeezes a 48dp control into the header's 40.
  group('WalkieHeader edge controls', () {
    const barKey = Key('bar');
    const barWidth = 360.0;

    Future<double> gapFromEnd(
      WidgetTester tester, {
      required double barInset,
      required Widget control,
      required Finder drawnEdge,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                key: barKey,
                width: barWidth,
                child: Padding(
                  padding: EdgeInsetsDirectional.only(end: barInset),
                  child: Row(children: [const Spacer(), control]),
                ),
              ),
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byKey(barKey));
      return bar.right - tester.getRect(drawnEdge).right;
    }

    testWidgets('the mic glyph lands on the column, not 8 short of it', (
      tester,
    ) async {
      final gap = await gapFromEnd(
        tester,
        barInset: WalkieHeaderLayout.inset(WalkieHeaderLayout.iconButtonInset),
        control: IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: () {},
          icon: const Icon(Icons.mic_rounded),
        ),
        drawnEdge: find.byIcon(Icons.mic_rounded),
      );
      expect(gap, WalkieHeaderLayout.opticalMargin);
    });

    testWidgets('the settings chip lands on the same column', (tester) async {
      final gap = await gapFromEnd(
        tester,
        barInset: WalkieHeaderLayout.inset(
          WalkieHeaderLayout.settingsChipInset,
        ),
        control: SizedBox(
          width: 40,
          height: 40,
          child: SettingsIconButton(onTap: () {}),
        ),
        drawnEdge: find.descendant(
          of: find.byType(SettingsIconButton),
          matching: find.byType(Container),
        ),
      );
      expect(gap, WalkieHeaderLayout.opticalMargin);
    });
  });
}
