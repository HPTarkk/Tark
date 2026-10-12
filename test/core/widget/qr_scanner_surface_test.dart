import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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
  Widget scanner({String? errorText, Future<bool> Function(String)? onCode}) =>
      MaterialApp(
        home: QrScannerSurface(
          title: 'Scan',
          hint: 'Point at the code',
          searchingLabel: 'Searching',
          lockedLabel: 'Got it',
          cameraDeniedLabel: 'Camera denied',
          cameraFailedLabel: 'Camera failed',
          openSettingsLabel: 'Settings',
          errorText: errorText,
          onCode: onCode ?? (_) async => true,
        ),
      );

  testWidgets('a failed handler releases the camera for another scan', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      scanner(
        onCode: (_) async {
          attempts++;
          if (attempts == 1) throw StateError('Network setup failed');
          return true;
        },
      ),
    );
    await tester.pump();
    final detect = tester
        .widget<MobileScanner>(find.byType(MobileScanner))
        .onDetect!;
    final capture = BarcodeCapture(
      barcodes: [Barcode(rawValue: 'WIFI:S:TARK;P:password;;')],
    );
    Object? error;
    final first = (detect as dynamic)(capture) as Future<void>;
    unawaited(
      first.catchError((Object failure) {
        error = failure;
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    final second = (detect as dynamic)(capture) as Future<void>;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await second;

    expect(attempts, 2);
    expect(error, isNull);
    expect(tester.takeException(), isNull);
  });

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

    double top() =>
        tester.getTopLeft(find.byKey(const Key('qr-scanner-sweep'))).dy;

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

  testWidgets('an accepted code that fails further on re-arms the camera', (
    tester,
  ) async {
    // 2026-10-12: the code was read and the join went through, then the
    // connection itself timed out and the screen said so — around a camera
    // that had locked for good on the accept and would never read again.
    var reads = 0;
    Future<bool> onCode(String _) async {
      reads++;
      return true;
    }

    await tester.pumpWidget(scanner(onCode: onCode));
    await tester.pump();
    final capture = BarcodeCapture(
      barcodes: [Barcode(rawValue: 'WIFI:S:TARK;P:password;;')],
    );
    Future<void> detect() async {
      final handler = tester
          .widget<MobileScanner>(find.byType(MobileScanner))
          .onDetect!;
      final read = (handler as dynamic)(capture) as Future<void>;
      // The lock ring animates before the handler is asked; its ticker only
      // starts on the next frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await read;
    }

    await detect();
    expect(reads, 1);

    // Locked: another read is ignored.
    await detect();
    expect(reads, 1);

    await tester.pumpWidget(
      scanner(onCode: onCode, errorText: 'Could not connect. Scan again.'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await detect();
    expect(reads, 2);
    expect(tester.takeException(), isNull);
  });
}
