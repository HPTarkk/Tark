import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/permission/permission_primer.dart';
import 'package:tark/core/permission/permission_primer_sheet.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';

import '../permission/fake_permission_backend.dart';

/// The scanner explains the camera before Android asks for it, and a "not
/// now" leaves a calm camera-off state with one way back — never a black
/// window, and never the same question again on every return to the app.
void main() {
  setUp(() {
    PermissionPrimer.resetForTest();
    PermissionPrimer.supportedOverride = (_) => true;
  });
  tearDown(PermissionPrimer.resetForTest);

  Widget scanner() => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: QrScannerSurface(
      title: 'Scan',
      hint: 'Point at the code',
      searchingLabel: 'Searching',
      lockedLabel: 'Got it',
      cameraDeniedLabel: 'Tarkk needs the camera to read the code.',
      cameraFailedLabel: 'Camera failed',
      openSettingsLabel: 'Settings',
      onCode: (_) async => true,
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('not now leaves the camera-off state; its action brings the '
      'primer back', (tester) async {
    final backend = FakePermissionBackend();
    PermissionPrimer.backend = backend;
    await tester.pumpWidget(scanner());
    await settle(tester);

    expect(find.byType(PermissionPrimerSheet), findsOneWidget);
    await tester.tap(find.byKey(const Key('permission-primer-not-now')));
    await settle(tester);

    expect(find.byType(PermissionPrimerSheet), findsNothing);
    expect(find.byKey(const Key('qr-scanner-camera-off')), findsOneWidget);
    expect(backend.requests, 0);

    // Coming back to the app only checks; it does not ask again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsNothing);

    await tester.tap(find.byKey(const Key('permission-denied-panel-action')));
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsOneWidget);
    await tester.tap(find.byKey(const Key('permission-primer-not-now')));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a camera already allowed opens with no primer at all', (
    tester,
  ) async {
    PermissionPrimer.backend = FakePermissionBackend(
      current: {Permission.camera: PermissionStatus.granted},
    );
    await tester.pumpWidget(scanner());
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsNothing);
    expect(find.byKey(const Key('qr-scanner-camera-off')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
