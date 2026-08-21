import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/preflight/presentation/page/preflight_sheet.dart';
import 'package:tark/feature/preflight/presentation/widget/silent_preflight_guard.dart';
import 'package:tark/feature/preflight/service/preflight_result.dart';
import 'package:tark/feature/preflight/service/preflight_service.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

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

/// A minimal stand-in for one of the four goLive destination pages: just
/// enough scaffolding to prove the mixin's own behavior, not a real screen.
class _HostPage extends StatefulWidget {
  const _HostPage({required this.starter});

  final PreflightSessionStarter starter;

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage>
    with SilentPreflightGuard<_HostPage> {
  @override
  TransferMode get preflightMode => TransferMode.bluetooth;

  @override
  PreflightSessionStarter get preflightStarter => widget.starter;

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('host page'));
}

Future<void> _pump(WidgetTester tester, PreflightSessionStarter starter) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: _HostPage(starter: starter),
    ),
  );
  // pinnedPlanFor does a genuine dart:io NetworkInterface.list() call, which
  // completes on the real event loop rather than the fake clock pump()
  // advances — runAsync is what lets that actually resolve mid-test.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  // Bounded, not pumpAndSettle: an all-green/blocked fixture resolves
  // instantly (no pending row), but the modal sheet's own entrance
  // transition still needs real frames to finish opening.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  testWidgets(
    'an all-green silent check never shows the sheet — the quick-access '
    'path stays instant',
    (tester) async {
      await _pump(
        tester,
        ({required s, required plan}) => PreflightSession.debugFixed(_allGreen),
      );

      expect(find.text('host page'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  testWidgets(
    'a hard failure forces the same full sheet the normal flow uses',
    (tester) async {
      await _pump(
        tester,
        ({required s, required plan}) => PreflightSession.debugFixed(_blocked),
      );

      // The blocked sheet's own CTA — proves the forced sheet is not a
      // separate, undertested surface.
      expect(find.text('FIX THE ISSUES ABOVE'), findsOneWidget);
    },
  );
}
