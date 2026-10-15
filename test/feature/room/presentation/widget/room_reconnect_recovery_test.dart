import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/presentation/widget/room_reconnect_view.dart';

/// Failure recovery and the role switch on the guided reconnect screen.
void main() {
  const show = RoomReconnectModel(
    side: RoomReconnectSide.show,
    peerName: 'Sara',
    phase: RoomReconnectPhase.waiting,
    qrData: 'WIFI:S:DIRECT-tark;T:WPA;P:secretpass;H:false;;',
  );
  const connecting = RoomReconnectModel(
    side: RoomReconnectSide.scan,
    peerName: 'Sara',
    phase: RoomReconnectPhase.connecting,
  );
  final failed = connecting.copyWith(phase: RoomReconnectPhase.failed);

  var switches = 0;

  Future<void> pump(
    WidgetTester tester,
    RoomReconnectModel model, {
    bool reduced = false,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(412, 915),
            disableAnimations: reduced,
          ),
          child: RoomReconnectView(
            model: model,
            onScan: (_) async => false,
            onSwitch: () => switches++,
            onRetry: () {},
            onBack: () {},
          ),
        ),
      ),
    );
  }

  Widget swapButton(WidgetTester tester) =>
      tester.widget(find.byKey(const Key('room-reconnect-switch')));

  setUp(() => switches = 0);

  testWidgets('one failure keeps Scan again first; the second promotes the '
      'swap', (tester) async {
    await pump(tester, connecting);
    await pump(tester, failed);
    await tester.pump(const Duration(seconds: 2));
    expect(swapButton(tester), isNot(isA<FilledButton>()));
    expect(
      tester.widget(find.byKey(const Key('room-reconnect-scan-again'))),
      isA<FilledButton>(),
    );

    await pump(tester, connecting);
    await tester.pump(const Duration(seconds: 1));
    await pump(tester, failed);
    await tester.pump(const Duration(seconds: 2));
    expect(swapButton(tester), isA<FilledButton>());
    expect(
      tester.widget(find.byKey(const Key('room-reconnect-scan-again'))),
      isNot(isA<FilledButton>()),
    );
    await tester.tap(find.byKey(const Key('room-reconnect-switch')));
    expect(switches, 1);
  });

  testWidgets('a declined join offers the swap first straight away', (
    tester,
  ) async {
    await pump(tester, connecting);
    await pump(
      tester,
      failed.copyWith(problem: RoomReconnectProblem.joinDeclined),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(swapButton(tester), isA<FilledButton>());
    // Said in plain words, not as a generic failure.
    expect(
      find.textContaining("couldn't get onto their phone's hotspot"),
      findsOneWidget,
    );
  });

  testWidgets('a code nobody scans suggests scanning instead after a while', (
    tester,
  ) async {
    await pump(tester, show);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('room-reconnect-linger-hint')), findsNothing);

    await tester.pump(RoomReconnectView.showLinger);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('room-reconnect-linger-hint')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final reduced in [false, true]) {
    testWidgets('switching sides turns the screen over with one live switch '
        '(reduced motion: $reduced)', (tester) async {
      await pump(tester, show, reduced: reduced);
      await tester.pump(const Duration(seconds: 1));

      await pump(tester, failed, reduced: reduced);
      for (var ms = 0; ms < 1000; ms += 50) {
        await tester.pump(const Duration(milliseconds: 50));
        // Only one side is ever reachable, mid-turn or not.
        expect(
          find
              .byKey(const Key('room-reconnect-switch'))
              .hitTestable()
              .evaluate()
              .length,
          lessThanOrEqualTo(1),
        );
      }
      await tester.pump(const Duration(seconds: 1));
      // The turn is over: the scanning side alone is left.
      expect(
        find.byKey(const ValueKey('room-reconnect-journey')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
      expect(find.byKey(const Key('room-reconnect-switch')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
