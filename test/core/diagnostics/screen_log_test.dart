import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/diagnostics/screen_log.dart';
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
  });

  tearDown(() => Logger.sink = null);

  Future<NavigatorState> pumpApp(WidgetTester tester) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        navigatorObservers: [ScreenLog()],
        initialRoute: 'LandingPage',
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => Text(settings.name ?? ''),
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
}
