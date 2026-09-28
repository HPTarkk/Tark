import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/log_detail.dart';
import 'package:tark/core/diagnostics/screen_log.dart';
import 'package:tark/core/diagnostics/tap_log.dart';
import 'package:tark/core/utils/logger.dart';

/// What lands in the .tarklog as the user moves around: the lines have to
/// name the screen, where it was opened from, and how long it stayed up, so a
/// log can be read (or mined) as a trail of screens.
void main() {
  late List<String> lines;

  setUp(() {
    lines = [];
    Logger.sink = lines.add;
    ScreenLog.debugReset();
    ScreenLog.detail = LogDetail.screens;
  });

  tearDown(() {
    Logger.sink = null;
    ScreenLog.debugReset();
  });

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [ScreenLog()],
        initialRoute: 'LandingPage',
        builder: (context, child) => TapLog(child: child!),
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('go-button'),
                onPressed: () {},
                child: Text('Go ${settings.name}'),
              ),
            ),
          ),
        ),
      ),
    );
    return key.currentState!;
  }

  testWidgets('logs pages opening and closing with where they came from', (
    tester,
  ) async {
    final nav = await pumpApp(tester);
    unawaited(nav.pushNamed('SettingsPage'));
    await tester.pumpAndSettle();
    nav.pop();
    await tester.pumpAndSettle();

    expect(lines[0], 'ui: open LandingPage');
    expect(lines[1], 'ui: open SettingsPage from LandingPage');
    expect(
      lines[2],
      matches(r'^ui: close SettingsPage after \d+\.\ds, back to LandingPage$'),
    );
    expect(ScreenLog.current, 'LandingPage');
  });

  testWidgets('names sheets and dialogs by their route settings', (
    tester,
  ) async {
    final nav = await pumpApp(tester);
    unawaited(
      showDialog<void>(
        context: nav.context,
        routeSettings: const RouteSettings(name: 'LeaveChannelDialog'),
        builder: (_) => const Text('leave?'),
      ),
    );
    await tester.pumpAndSettle();

    expect(lines.last, 'ui: open LeaveChannelDialog from LandingPage');
  });

  testWidgets('falls back to the route kind when a route has no name', (
    tester,
  ) async {
    final nav = await pumpApp(tester);
    unawaited(
      showModalBottomSheet<void>(
        context: nav.context,
        builder: (_) => const Text('sheet'),
      ),
    );
    await tester.pumpAndSettle();
    expect(lines.last, 'ui: open sheet from LandingPage');

    nav.pop();
    await tester.pumpAndSettle();
    unawaited(
      showDialog<void>(context: nav.context, builder: (_) => const Text('d')),
    );
    await tester.pumpAndSettle();
    expect(lines.last, 'ui: open dialog from LandingPage');
  });

  testWidgets('taps and tabs say which screen they happened on', (
    tester,
  ) async {
    await pumpApp(tester);
    ScreenLog.tap('Start');
    ScreenLog.tab('hotspot');

    expect(lines, contains('ui: tap Start on LandingPage'));
    expect(lines, contains('ui: tab hotspot on LandingPage'));
  });

  testWidgets('standard, the default, writes no user-activity lines', (
    tester,
  ) async {
    ScreenLog.detail = LogDetail.standard;
    final nav = await pumpApp(tester);
    unawaited(nav.pushNamed('SettingsPage'));
    await tester.pumpAndSettle();
    ScreenLog.tap('Start');
    ScreenLog.setting('hd_voice_enabled', false);
    await tester.tap(find.byKey(const ValueKey('go-button')));
    await tester.pump(ScreenLog.settleDelay * 2);

    expect(lines, isEmpty);
    // Still tracked, so raising the level names the right screen at once.
    expect(ScreenLog.current, 'SettingsPage');
  });

  testWidgets('screens level logs no touches or settings', (tester) async {
    await pumpApp(tester);
    lines.clear();
    ScreenLog.setting('hd_voice_enabled', false);
    await tester.tap(find.byKey(const ValueKey('go-button')));
    await tester.pump(ScreenLog.settleDelay * 2);

    expect(lines, isEmpty);
  });

  testWidgets('everything logs each tap with what was tapped', (tester) async {
    ScreenLog.detail = LogDetail.everything;
    await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('go-button')));
    await tester.pump();

    expect(
      lines.last,
      'ui: touch "Go LandingPage" [go-button] (TextButton) on LandingPage',
    );
  });

  testWidgets('everything logs a setting once it settles', (tester) async {
    ScreenLog.detail = LogDetail.everything;
    await pumpApp(tester);
    lines.clear();
    // A slider drag: many writes, one line with the value it ended on.
    for (final v in [0.1, 0.2, 0.3]) {
      ScreenLog.setting('vox_margin', v);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(lines, isEmpty);
    await tester.pump(ScreenLog.settleDelay);

    expect(lines, ['ui: setting vox_margin = 0.3']);
  });
}
