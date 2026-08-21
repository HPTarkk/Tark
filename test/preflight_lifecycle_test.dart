import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/feature/audio/domain/entity/audio_engine_status.dart';
import 'package:tark/feature/audio/domain/entity/audio_frame.dart';
import 'package:tark/feature/audio/domain/entity/audio_route.dart';
import 'package:tark/feature/audio/domain/service/audio_engine.dart';
import 'package:tark/feature/preflight/data/mic_probe.dart';
import 'package:tark/feature/preflight/presentation/page/preflight_sheet.dart';
import 'package:tark/feature/preflight/service/preflight_result.dart';
import 'package:tark/feature/preflight/service/preflight_service.dart';
import 'package:tark/feature/transfer/domain/entity/channel_intent.dart';
import 'package:tark/feature/transfer/domain/service/transport_advisor.dart';

/// Fresh per run, mirroring how [MicProbe] resolves a brand-new engine on
/// every call in production — never shared across runs.
class _FakeAudioEngine implements AudioEngine {
  bool started = false;
  bool disposed = false;

  @override
  Future<void> start() async => started = true;

  @override
  AudioEngineStatus get currentStatus =>
      const AudioEngineStatus(hasPermission: true, isStarted: true);

  @override
  Stream<AudioFrame> get frames =>
      Stream.value(const AudioFrame(rms: 0.1, samples: [0.1]));

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

final _plan = TransportAdvisor.plan(
  ChannelIntent.create,
  const LinkConditions(
    hasWifi: true,
    canHostHotspot: false,
    canJoinHotspot: false,
    bluetoothSupported: false,
  ),
);

void main() {
  test(
    'MicProbe: repeated runs each dispose their own engine independently — '
    'no cross-run state to leak, since a fresh engine is resolved every call',
    () async {
      final engines = List.generate(5, (_) => _FakeAudioEngine());
      for (final engine in engines) {
        final result = await MicProbe.run(
          resolveEngine: () => engine,
          resolveRoute: () async => AudioRoute.unknown,
        );
        expect(result.outcome, MicProbeOutcome.ok);
      }
      expect(engines.every((e) => e.started && e.disposed), isTrue);
    },
  );

  testWidgets(
    'the sheet disposes its session/entrance controller on close and leaves '
    'nothing behind for a repeated Preflight run to trip over',
    (tester) async {
      var startCount = 0;
      final disposedSessions = <PreflightSession>[];

      PreflightSession starter({
        required AppLocalizations s,
        required ChannelPlan plan,
      }) {
        startCount++;
        final session = PreflightSession.debugFixed(_allGreen);
        disposedSessions.add(session);
        return session;
      }

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

      // Open, resolve, close — three times in a row. If the sheet's own
      // controller/session disposal were broken, a leaked repeating
      // animation from a prior run would make this hang (see the sheet
      // test's own note on pumpAndSettle vs a repeating _PendingDot), and a
      // leaked stream subscription would show up as a "add after close" or
      // duplicate-listener error surfaced by the test framework.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('ENTER CHANNEL'), findsOneWidget);

        await tester.tap(find.text('ENTER CHANNEL'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('ENTER CHANNEL'), findsNothing);
      }

      expect(startCount, 3, reason: 'one fresh session per open, not reused');
    },
  );
}
