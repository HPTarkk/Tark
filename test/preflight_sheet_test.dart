import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/l10n/app_localizations_en.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/presentation/page/preflight_sheet.dart';
import 'package:tark/feature/preflight/service/preflight_result.dart';
import 'package:tark/feature/preflight/service/preflight_service.dart';
import 'package:tark/feature/transfer/domain/entity/channel_intent.dart';
import 'package:tark/feature/transfer/domain/service/transport_advisor.dart';

final _s = AppLocalizationsEn();

RecoveryCheck _row(RecoveryStatus status, {String detail = 'detail'}) =>
    RecoveryCheck(label: 'label', detail: detail, status: status);

/// Every row resolved, all ok — the sheet's fully-ready state.
final _allGreen = PreflightResult(
  mic: _row(RecoveryStatus.ok, detail: 'mic ok'),
  route: _row(RecoveryStatus.ok, detail: 'route ok'),
  connection: _row(RecoveryStatus.ok, detail: 'connection ok'),
  background: _row(RecoveryStatus.ok, detail: 'background ok'),
  hdVoice: _row(RecoveryStatus.ok, detail: 'hd ok'),
  sharedMusic: _row(RecoveryStatus.ok, detail: 'music ok'),
  diagnostics: _row(RecoveryStatus.ok),
);

final _plan = TransportAdvisor.plan(
  ChannelIntent.create,
  const LinkConditions(
    hasWifi: true,
    canHostHotspot: false,
    canJoinHotspot: false,
    bluetoothSupported: false,
  ),
);

/// Opens the sheet with [starter] wired in.
///
/// Deliberately a bounded `pump(duration)`, not `pumpAndSettle()`: an
/// incomplete [PreflightResult] leaves a row's `_PendingDot` repeating
/// forever (by design — it's the "still checking" breathing dot), and
/// `pumpAndSettle` hangs waiting for an animation that never finishes. The
/// modal sheet's own entrance transition and this sheet's row-entrance
/// controller are both comfortably done well within 700ms.
Future<void> _openSheet(
  WidgetTester tester,
  PreflightSessionStarter starter,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPreflightSheet(
                context,
                plan: _plan,
                startSession: starter,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  group('CTA gating', () {
    testWidgets('all green enables the CTA with "ENTER CHANNEL"', (
      tester,
    ) async {
      await _openSheet(
        tester,
        ({required s, required plan}) => PreflightSession.debugFixed(_allGreen),
      );

      expect(find.text('ENTER CHANNEL'), findsOneWidget);
      await tester.tap(find.text('ENTER CHANNEL'));
      await tester.pumpAndSettle();
      expect(find.text('ENTER CHANNEL'), findsNothing, reason: 'sheet closed');
    });

    testWidgets('a hard failure disables the CTA and blocks proceeding', (
      tester,
    ) async {
      final blocked = PreflightResult(
        mic: _row(RecoveryStatus.bad, detail: 'mic denied'),
        route: _allGreen.route,
        connection: _allGreen.connection,
        background: _allGreen.background,
        hdVoice: _allGreen.hdVoice,
        sharedMusic: _allGreen.sharedMusic,
        diagnostics: _allGreen.diagnostics,
      );

      await _openSheet(
        tester,
        ({required s, required plan}) => PreflightSession.debugFixed(blocked),
      );

      expect(find.text('FIX THE ISSUES ABOVE'), findsOneWidget);
      await tester.tap(find.text('FIX THE ISSUES ABOVE'));
      await tester.pumpAndSettle();
      // Still open — a blocked CTA must not be tappable.
      expect(find.text('FIX THE ISSUES ABOVE'), findsOneWidget);
    });

    testWidgets('a warning-only state offers "CONTINUE ANYWAY", enabled', (
      tester,
    ) async {
      final warnOnly = PreflightResult(
        mic: _allGreen.mic,
        route: _row(RecoveryStatus.warn, detail: 'phone speaker'),
        connection: _allGreen.connection,
        background: _allGreen.background,
        hdVoice: _allGreen.hdVoice,
        sharedMusic: _allGreen.sharedMusic,
        diagnostics: _allGreen.diagnostics,
      );

      await _openSheet(
        tester,
        ({required s, required plan}) => PreflightSession.debugFixed(warnOnly),
      );

      expect(find.text('CONTINUE ANYWAY'), findsOneWidget);
      await tester.tap(find.text('CONTINUE ANYWAY'));
      await tester.pumpAndSettle();
      expect(find.text('CONTINUE ANYWAY'), findsNothing, reason: 'sheet closed');
    });

    testWidgets('an unknown row never blocks or changes the CTA label', (
      tester,
    ) async {
      final withUnknown = PreflightResult(
        mic: _allGreen.mic,
        route: _allGreen.route,
        connection: _allGreen.connection,
        background: _allGreen.background,
        hdVoice: _row(RecoveryStatus.unknown, detail: 'no peer yet'),
        sharedMusic: _row(RecoveryStatus.unknown, detail: 'not supported'),
        diagnostics: _allGreen.diagnostics,
      );

      await _openSheet(
        tester,
        ({required s, required plan}) =>
            PreflightSession.debugFixed(withUnknown),
      );

      expect(find.text('ENTER CHANNEL'), findsOneWidget);
    });
  });

  group('row rendering', () {
    testWidgets('a pending row shows a placeholder, then resolves in place', (
      tester,
    ) async {
      const incomplete = PreflightResult();
      final controller = StreamController<PreflightResult>();
      addTearDown(controller.close);

      await _openSheet(
        tester,
        ({required s, required plan}) => PreflightSession.debugStream(
          initial: incomplete,
          results: controller.stream,
        ),
      );

      // Nothing resolved yet: only the fixed "Checking…" placeholder text
      // appears (once per still-pending row), never a real detail line.
      expect(find.text(_s.preflight_checking), findsWidgets);
      expect(find.text('mic ok'), findsNothing);

      controller.add(_allGreen);
      await tester.pump();
      // Long enough to clear the icon cross-fade (260ms) that removes the
      // last _PendingDot — pumpAndSettle would hang on it, same as above.
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('mic ok'), findsOneWidget);
      expect(find.text('connection ok'), findsOneWidget);
    });
  });
}
