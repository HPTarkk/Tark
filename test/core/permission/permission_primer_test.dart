import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/l10n/app_localizations_fa.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/core/permission/permission_denied_panel.dart';
import 'package:tark/core/permission/permission_flow.dart';
import 'package:tark/core/permission/permission_primer.dart';
import 'package:tark/core/permission/permission_primer_sheet.dart';

import 'fake_permission_backend.dart';

void main() {
  late FakePermissionBackend backend;

  setUp(() {
    PermissionPrimer.resetForTest();
    PermissionPrimer.supportedOverride = (_) => true;
  });
  tearDown(PermissionPrimer.resetForTest);

  void useBackend(FakePermissionBackend b) {
    backend = b;
    PermissionPrimer.backend = b;
  }

  /// A screen with one button that asks for [permissions] and keeps the
  /// answer.
  Widget app({
    required List<Permission> permissions,
    required PermissionKind kind,
    required void Function(Map<Permission, PermissionStatus>) onResult,
    Locale locale = const Locale('en'),
  }) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async => onResult(
              await PermissionPrimer.request(
                permissions,
                kind: kind,
                context: context,
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ),
  );

  Future<Map<Permission, PermissionStatus>?> ask(
    WidgetTester tester, {
    List<Permission> permissions = const [Permission.microphone],
    PermissionKind kind = PermissionKind.microphone,
    Locale locale = const Locale('en'),
    void Function(Map<Permission, PermissionStatus>)? onResult,
  }) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      app(
        permissions: permissions,
        kind: kind,
        locale: locale,
        onResult: onResult ?? (_) {},
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    return null;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  final en = AppLocalizationsEn();

  testWidgets('an already-granted permission shows nothing at all', (
    tester,
  ) async {
    useBackend(
      FakePermissionBackend(
        current: {Permission.microphone: PermissionStatus.granted},
      ),
    );
    Map<Permission, PermissionStatus>? result;
    await ask(tester, onResult: (r) => result = r);
    expect(find.byType(PermissionPrimerSheet), findsNothing);
    expect(result?[Permission.microphone], PermissionStatus.granted);
    expect(backend.requests, 0);
  });

  testWidgets('the primer comes first; the OS is asked only on Allow, and '
      'a grant closes it by itself after the success beat', (tester) async {
    useBackend(FakePermissionBackend()..dialog = Completer<void>());
    Map<Permission, PermissionStatus>? result;
    await ask(tester, onResult: (r) => result = r);

    expect(find.byType(PermissionPrimerSheet), findsOneWidget);
    expect(find.text(en.perm_mic_title), findsOneWidget);
    expect(find.text(en.perm_mic_promise), findsOneWidget);
    expect(find.text(en.perm_not_now), findsOneWidget);
    expect(backend.requests, 0);

    await tester.tap(find.byKey(const Key('permission-primer-primary')));
    await tester.pump();
    expect(backend.requests, 1);
    backend.dialog!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(en.perm_granted_title), findsOneWidget);
    expect(result, isNull, reason: 'the success beat is still on screen');

    await tester.pump(AppMotion.successBeat);
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsNothing);
    expect(result?[Permission.microphone], PermissionStatus.granted);
  });

  testWidgets('Not now closes without asking and answers denied', (
    tester,
  ) async {
    useBackend(FakePermissionBackend());
    Map<Permission, PermissionStatus>? result;
    await ask(tester, onResult: (r) => result = r);
    await tester.tap(find.byKey(const Key('permission-primer-not-now')));
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsNothing);
    expect(backend.requests, 0);
    expect(result?[Permission.microphone]?.isGranted, isFalse);
  });

  testWidgets('a refusal settles into the denied state; Ask me again goes '
      'straight back to the OS', (tester) async {
    useBackend(
      FakePermissionBackend(
        answers: [PermissionStatus.denied, PermissionStatus.granted],
      ),
    );
    Map<Permission, PermissionStatus>? result;
    await ask(tester, onResult: (r) => result = r);
    await tester.tap(find.byKey(const Key('permission-primer-primary')));
    await settle(tester);
    expect(find.text(en.perm_denied_title), findsOneWidget);
    expect(find.text(en.perm_mic_denied), findsOneWidget);
    expect(find.text(en.perm_try_again), findsOneWidget);

    await tester.tap(find.byKey(const Key('permission-primer-primary')));
    await settle(tester);
    await tester.pump(AppMotion.successBeat);
    await settle(tester);
    expect(backend.requests, 2);
    expect(result?[Permission.microphone], PermissionStatus.granted);
  });

  testWidgets('blocked: Open settings, and a grant made there is picked up '
      'on return without another tap', (tester) async {
    useBackend(
      FakePermissionBackend(answers: [PermissionStatus.permanentlyDenied]),
    );
    Map<Permission, PermissionStatus>? result;
    await ask(tester, onResult: (r) => result = r);
    await tester.tap(find.byKey(const Key('permission-primer-primary')));
    await settle(tester);
    expect(find.text(en.perm_blocked_title), findsOneWidget);
    expect(find.text(en.perm_open_settings), findsOneWidget);

    await tester.tap(find.byKey(const Key('permission-primer-primary')));
    await settle(tester);
    expect(backend.settingsOpened, 1);
    expect(find.text(en.perm_waiting), findsOneWidget);

    backend.current[Permission.microphone] = PermissionStatus.granted;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(en.perm_granted_title), findsOneWidget);
    await tester.pump(AppMotion.successBeat);
    await settle(tester);
    expect(result?[Permission.microphone], PermissionStatus.granted);
    expect(backend.requests, 1);
  });

  testWidgets('two requests at once are shown one after the other', (
    tester,
  ) async {
    useBackend(FakePermissionBackend());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              unawaited(
                PermissionPrimer.request(const [
                  Permission.microphone,
                ], context: context),
              );
              unawaited(
                PermissionPrimer.request(const [
                  Permission.camera,
                ], context: context),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsOneWidget);
    expect(find.text(en.perm_mic_title), findsOneWidget);
    await tester.tap(find.byKey(const Key('permission-primer-not-now')));
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsOneWidget);
    expect(find.text(en.perm_camera_title), findsOneWidget);
    await tester.tap(find.byKey(const Key('permission-primer-not-now')));
    await settle(tester);
    expect(find.byType(PermissionPrimerSheet), findsNothing);
  });

  test('an unsupported platform asks the OS directly, as before', () async {
    useBackend(FakePermissionBackend());
    PermissionPrimer.supportedOverride = (_) => false;
    final result = await PermissionPrimer.request(const [Permission.camera]);
    expect(backend.requests, 1);
    expect(result[Permission.camera], PermissionStatus.granted);
  });

  test('with nowhere to show the primer, the OS is asked directly', () async {
    useBackend(FakePermissionBackend());
    final result = await PermissionPrimer.request(const [
      Permission.microphone,
    ]);
    expect(backend.requests, 1);
    expect(result[Permission.microphone], PermissionStatus.granted);
  });

  test('an unreadable status falls back to the direct request', () async {
    useBackend(FakePermissionBackend(throwOnStatus: true));
    await PermissionPrimer.request(const [Permission.microphone]);
    expect(backend.requests, 1);
  });

  // Every state, every kind, both languages: renders whole, says the right
  // thing, and throws nothing.
  for (final locale in const [Locale('fa'), Locale('en')]) {
    final s = locale.languageCode == 'fa'
        ? AppLocalizationsFa()
        : AppLocalizationsEn();
    for (final kind in PermissionKind.values) {
      testWidgets('${kind.name} in ${locale.languageCode}: primer, denied, '
          'blocked and granted', (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 740));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final copy = PermissionCopy.of(s, kind);
        final permission = switch (kind) {
          PermissionKind.microphone => Permission.microphone,
          PermissionKind.camera => Permission.camera,
          PermissionKind.nearbyDevices => Permission.bluetoothScan,
          PermissionKind.nearbyWifi => Permission.nearbyWifiDevices,
          PermissionKind.location => Permission.locationWhenInUse,
          PermissionKind.notifications => Permission.notification,
        };

        Future<void> show(
          List<PermissionStatus> answers,
          String expected, {
          int allows = 0,
        }) async {
          final b = FakePermissionBackend(answers: answers);
          final flow = PermissionFlowController(
            permissions: [permission],
            kind: kind,
            backend: b,
          );
          await flow.start();
          if (allows > 0) await flow.allow();
          if (allows > 1) await flow.retry();
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: PermissionPrimerSheet(flow: flow),
                ),
              ),
            ),
          );
          await settle(tester);
          expect(find.text(expected), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          flow.dispose();
        }

        await show(const [], copy.title);
        await show(const [PermissionStatus.denied], copy.denied, allows: 1);
        await show(
          const [PermissionStatus.permanentlyDenied],
          s.perm_blocked_title,
          allows: 1,
        );
        await show(
          const [PermissionStatus.granted],
          s.perm_granted_title,
          allows: 1,
        );
      });
    }
  }

  testWidgets('the denied panel settles in and offers its action', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PermissionDeniedPanel(
            kind: PermissionKind.camera,
            title: 'Off for now',
            message: 'The camera reads the code.',
            actionLabel: 'Turn on the camera',
            onAction: () => taps++,
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('permission-denied-panel-action')));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion: nothing loops', (tester) async {
    useBackend(FakePermissionBackend());
    final flow = PermissionFlowController(
      permissions: const [Permission.microphone],
      kind: PermissionKind.microphone,
      backend: backend,
    );
    await flow.start();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: PermissionPrimerSheet(flow: flow)),
        ),
      ),
    );
    await settle(tester);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox());
    flow.dispose();
  });
}
