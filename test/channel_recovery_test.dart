import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/recovery/recovery_action.dart';
import 'package:tark/core/recovery/recovery_banner.dart';
import 'package:tark/core/recovery/recovery_check.dart';
import 'package:tark/core/recovery/recovery_sheet.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';
import 'package:tark/feature/walkie/presentation/manager/walkie_talkie_cubit.dart';
import 'package:tark/feature/walkie/presentation/widget/channel_recovery.dart';

/// A live, healthy Wi-Fi session — the baseline every case below breaks in
/// exactly one way.
WalkieTalkieState healthy() => WalkieTalkieState.initial().copyWith(
  isReady: true,
  localId: '192.168.1.42',
  transferMode: TransferMode.wifi,
);

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: SizedBox(width: 360, child: child))),
);

void main() {
  group('which problem leads', () {
    test('a healthy session leads with nothing', () {
      expect(channelIssueOf(healthy()), ChannelIssue.none);
    });

    test('a channel that never opened outranks everything', () {
      final state = healthy().copyWith(
        startFailed: true,
        hasPermission: false,
        networkMissing: true,
        micDelivering: false,
        isAlone: true,
      );
      expect(channelIssueOf(state), ChannelIssue.startFailed);
    });

    test('a refused mic outranks having nowhere to send', () {
      final state = healthy().copyWith(
        hasPermission: false,
        networkMissing: true,
      );
      expect(channelIssueOf(state), ChannelIssue.micDenied);
    });

    test('no address outranks a silent mic', () {
      final state = healthy().copyWith(
        networkMissing: true,
        micDelivering: false,
      );
      expect(channelIssueOf(state), ChannelIssue.noNetwork);
    });

    test('a mic that is allowed but delivers nothing is reported', () {
      expect(
        channelIssueOf(healthy().copyWith(micDelivering: false)),
        ChannelIssue.micSilent,
      );
    });
  });

  group('being alone', () {
    test('an empty channel is not an issue until it has had time', () {
      // isAlone is only set by the cubit once the grace has passed; before
      // that an empty channel is just a new one.
      expect(channelIssueOf(healthy()), ChannelIssue.none);
    });

    test('is reported once the grace has passed', () {
      expect(
        channelIssueOf(healthy().copyWith(isAlone: true)),
        ChannelIssue.alone,
      );
    });

    test('stays quiet while the link itself is unwell', () {
      // The health banner is already explaining the silence — saying "nobody
      // is here" on top of it would read as a second, separate fault.
      final state = healthy().copyWith(
        isAlone: true,
        connectionHealth: const ConnectionHealth.reconnecting(),
      );
      expect(channelIssueOf(state), ChannelIssue.none);
    });
  });

  group('mute-to-the-world', () {
    test('is false for a working session', () {
      expect(healthy().isMuteToTheWorld, isFalse);
    });

    test('covers every way a voice can fail to leave the phone', () {
      expect(healthy().copyWith(startFailed: true).isMuteToTheWorld, isTrue);
      expect(healthy().copyWith(hasPermission: false).isMuteToTheWorld, isTrue);
      expect(healthy().copyWith(micDelivering: false).isMuteToTheWorld, isTrue);
      expect(healthy().copyWith(networkMissing: true).isMuteToTheWorld, isTrue);
    });

    test('self-mute is not one of them — that one is deliberate', () {
      expect(healthy().copyWith(isSelfMuted: true).isMuteToTheWorld, isFalse);
    });
  });

  group('the banner', () {
    testWidgets('takes no space when nothing is wrong', (tester) async {
      await tester.pumpWidget(wrap(const RecoveryBanner(issue: null)));
      expect(tester.getSize(find.byType(RecoveryBanner)).height, 0);
    });

    testWidgets('a healthy check is not drawn as a problem', (tester) async {
      await tester.pumpWidget(
        wrap(
          const RecoveryBanner(
            issue: RecoveryCheck(
              label: 'Microphone',
              detail: 'Working',
              status: RecoveryStatus.ok,
            ),
          ),
        ),
      );
      expect(find.text('Microphone'), findsNothing);
    });

    testWidgets('shows the problem and its fixes', (tester) async {
      var ran = 0;
      await tester.pumpWidget(
        wrap(
          RecoveryBanner(
            issue: RecoveryCheck(
              label: 'Nobody can hear you',
              detail: 'Tarkk needs permission to use your microphone.',
              status: RecoveryStatus.bad,
              actions: [
                RecoveryAction(
                  label: 'ALLOW MIC',
                  isPrimary: true,
                  run: () async => ran++,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Nobody can hear you'), findsOneWidget);
      expect(find.text('ALLOW MIC'), findsOneWidget);

      await tester.tap(find.text('ALLOW MIC'));
      await tester.pumpAndSettle();
      expect(ran, 1);
    });

    testWidgets('a slow fix cannot be double-fired by an impatient tap', (
      tester,
    ) async {
      var ran = 0;
      await tester.pumpWidget(
        wrap(
          RecoveryBanner(
            issue: RecoveryCheck(
              label: 'No network',
              detail: 'Not on Wi-Fi.',
              status: RecoveryStatus.bad,
              actions: [
                RecoveryAction(
                  label: 'RECONNECT',
                  run: () async {
                    ran++;
                    await Future<void>.delayed(
                      const Duration(milliseconds: 300),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('RECONNECT'));
      await tester.pump();
      await tester.tap(find.text('RECONNECT'));
      await tester.pump();
      expect(ran, 1);

      await tester.pumpAndSettle();
    });
  });

  group('the troubleshooting sheet', () {
    testWidgets('lays out on a small phone without overflowing', (
      tester,
    ) async {
      // 320 logical px is the narrowest phone still in the wild. A fix the
      // user cannot read or reach is not a way out, so the sheet has to hold
      // long labels and two chips at this width — any RenderFlex overflow
      // here fails the test.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showRecoverySheet(
                    context,
                    initial: rows(),
                    checks: const Stream<List<RecoveryCheck>>.empty(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text("What's going on?"), findsOneWidget);
      // Healthy rows are shown too — "network: connected" is what tells
      // someone the fault is at the other end.
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text("Tarkk isn't allowed to use it"), findsOneWidget);
      expect(find.text('ALLOW MIC'), findsOneWidget);
    });

    testWidgets('says so plainly when every check passes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showRecoverySheet(
                    context,
                    initial: const [
                      RecoveryCheck(
                        label: 'Microphone',
                        detail: 'Working',
                        status: RecoveryStatus.ok,
                      ),
                    ],
                    checks: const Stream<List<RecoveryCheck>>.empty(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The "is it me?" answer. An all-green sheet still has to say something.
      expect(
        find.textContaining('Everything checks out'),
        findsOneWidget,
      );
    });
  });
}

List<RecoveryCheck> rows() => [
  RecoveryCheck(
    label: 'Microphone',
    detail: "Tarkk isn't allowed to use it",
    status: RecoveryStatus.bad,
    actions: [
      RecoveryAction(label: 'ALLOW MIC', isPrimary: true, run: () async {}),
      RecoveryAction(label: 'OPEN SETTINGS', run: () async {}),
    ],
  ),
  const RecoveryCheck(
    label: 'Network',
    detail: 'Connected',
    status: RecoveryStatus.ok,
  ),
];
