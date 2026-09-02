import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';

/// The scanner's HUD, guarded against the failure that took two of its parts
/// out at once.
///
/// The reported symptoms were "a white veil over the window" and "the radar is
/// gone", which read as two separate cosmetic faults. They were one: the
/// travelling scanline's `Positioned` lost the `Stack` it needs when this
/// widget was extracted out of the hotspot scanner, so the strip threw on
/// mount — and a release build fills a thrown subtree with `RenderErrorBox`,
/// which paints `0xF0C0C0C0`. An almost-opaque light grey, clipped to exactly
/// the rounded reticle window. The veil *was* the missing radar.
///
/// Debug builds paint that box red instead, which is why an assertion here is
/// worth more than looking at the screen: the two builds fail differently and
/// only one of them looks like a bug.
void main() {
  Widget scanner({String? errorText}) => MaterialApp(
    home: QrScannerSurface(
      title: 'Scan',
      hint: 'Point at the code',
      searchingLabel: 'Searching',
      lockedLabel: 'Got it',
      cameraDeniedLabel: 'Camera denied',
      cameraFailedLabel: 'Camera failed',
      openSettingsLabel: 'Settings',
      errorText: errorText,
      onCode: (_) async => true,
    ),
  );

  testWidgets('the HUD mounts whole, with nothing thrown behind it', (
    tester,
  ) async {
    await tester.pumpWidget(scanner());
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    // The specific shape of the regression: an ErrorWidget standing in for a
    // subtree is invisible in a release build except as a coloured rectangle.
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byKey(const Key('qr-scanner-sweep')), findsOneWidget);
  });

  testWidgets('the sweep travels rather than sitting still', (tester) async {
    await tester.pumpWidget(scanner());
    await tester.pump(const Duration(milliseconds: 100));

    double top() => tester
        .getTopLeft(find.byKey(const Key('qr-scanner-sweep')))
        .dy;

    final start = top();
    await tester.pump(const Duration(milliseconds: 400));
    final moved = top();
    await tester.pump(const Duration(milliseconds: 400));

    // "Still looking" is the only thing this animation says, so a stationary
    // strip is the same as no strip at all.
    expect(moved, isNot(closeTo(start, 0.5)));
    expect(top(), isNot(closeTo(moved, 0.5)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected code re-arms rather than dead-ending', (
    tester,
  ) async {
    await tester.pumpWidget(scanner());
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(scanner(errorText: 'That code has expired'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('That code has expired'), findsOneWidget);
    expect(find.byKey(const Key('qr-scanner-sweep')), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
