import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/presentation/page/preflight_sheet.dart';
import 'package:tark/feature/preflight/service/preflight_result.dart';
import 'package:tark/feature/preflight/service/preflight_service.dart';
import 'package:tark/feature/transfer/domain/entity/channel_intent.dart';
import 'package:tark/feature/transfer/domain/service/transport_advisor.dart';

RecoveryCheck _row(RecoveryStatus status) =>
    RecoveryCheck(label: 'label', detail: 'detail', status: status);

final _allGreen = PreflightResult(
  mic: _row(RecoveryStatus.ok),
  route: _row(RecoveryStatus.ok),
  connection: _row(RecoveryStatus.ok),
  background: _row(RecoveryStatus.ok),
  hdVoice: _row(RecoveryStatus.ok),
  sharedMusic: _row(RecoveryStatus.ok),
  diagnostics: _row(RecoveryStatus.ok),
);

final _blocked = PreflightResult(
  mic: _row(RecoveryStatus.bad),
  route: _allGreen.route,
  connection: _allGreen.connection,
  background: _allGreen.background,
  hdVoice: _allGreen.hdVoice,
  sharedMusic: _allGreen.sharedMusic,
  diagnostics: _allGreen.diagnostics,
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

Future<void> _openSheet(
  WidgetTester tester,
  PreflightResult result, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPreflightSheet(
                context,
                plan: _plan,
                startSession: ({required s, required plan}) =>
                    PreflightSession.debugFixed(result),
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
  group('accessibility', () {
    testWidgets(
      'the ready CTA exposes an enabled, tappable button node',
      (tester) async {
        await _openSheet(tester, _allGreen);

        // matchesSemantics is the framework's own idiom for this — reading
        // SemanticsData fields off tester.getSemantics(...) directly proved
        // unreliable here (it can resolve against a pre-merge node rather
        // than the final tree toStringDeep() confirms is correct: one node,
        // flags "isButton, hasEnabledState, isEnabled", label "ENTER CHANNEL").
        expect(
          tester.getSemantics(find.bySemanticsLabel('ENTER CHANNEL')),
          matchesSemantics(
            label: 'ENTER CHANNEL',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
      },
      semanticsEnabled: true,
    );

    testWidgets(
      'a blocked CTA exposes a button node with no tap action — a screen '
      'reader must not announce it as usable',
      (tester) async {
        await _openSheet(tester, _blocked);

        expect(
          tester.getSemantics(find.bySemanticsLabel('FIX THE ISSUES ABOVE')),
          matchesSemantics(
            label: 'FIX THE ISSUES ABOVE',
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
      },
      semanticsEnabled: true,
    );
  });

  group('RTL / localization', () {
    testWidgets(
      'lays out right-to-left in Farsi on a small phone without overflowing',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await _openSheet(tester, _blocked, locale: const Locale('fa'));

        expect(find.text('بررسی قبل از حرکت'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a warn-only Farsi sheet also lays out without overflowing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final warnOnly = PreflightResult(
        mic: _allGreen.mic,
        route: _row(RecoveryStatus.warn),
        connection: _allGreen.connection,
        background: _allGreen.background,
        hdVoice: _allGreen.hdVoice,
        sharedMusic: _allGreen.sharedMusic,
        diagnostics: _allGreen.diagnostics,
      );

      await _openSheet(tester, warnOnly, locale: const Locale('fa'));

      expect(find.text('به هر حال ادامه بده'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
