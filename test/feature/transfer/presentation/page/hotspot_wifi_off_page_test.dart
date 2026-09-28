import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/presentation/page/hotspot_wifi_off_page.dart';

/// A host whose radio the test flips.
class _Host implements HotspotHost {
  bool wifiOn;
  int panels = 0;

  _Host({required this.wifiOn});

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async =>
      HotspotWifiAdvice(wifiEnabled: wifiOn, concurrent: true, canPanel: true);

  @override
  Future<bool> openWifiPanel() async {
    panels++;
    return true;
  }

  @override
  Future<HotspotCredentials> start() => throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Host host;
  late List<HotspotWifiOffResult?> results;

  Future<void> pumpHostScreen(WidgetTester tester, {bool wifiOn = true}) async {
    host = _Host(wifiOn: wifiOn);
    results = [];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => results.add(
                await HotspotWifiOffPage.showIfWifiOn(context, host),
              ),
              child: const Text('host'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('shows nothing when Wi-Fi is already off', (tester) async {
    await pumpHostScreen(tester, wifiOn: false);

    expect(find.byType(HotspotWifiOffPage), findsNothing);
    expect(results, [null]);
  });

  testWidgets('asks the host to turn Wi-Fi off when it is on', (tester) async {
    await pumpHostScreen(tester);

    expect(find.byType(HotspotWifiOffPage), findsOneWidget);
    expect(find.text('Turn off Wi-Fi for a steadier connection'), findsOne);
    expect(find.text('Wi-Fi is on'), findsOneWidget);

    await tester.tap(find.text('Turn Wi-Fi off'));
    await tester.pump();
    expect(host.panels, 1);

    // Leave the page with its ambient loop stopped.
    await tester.tap(find.text('Continue anyway'));
    await tester.pumpAndSettle();
  });

  testWidgets('Continue anyway leaves with Wi-Fi still on', (tester) async {
    await pumpHostScreen(tester);

    await tester.tap(find.text('Continue anyway'));
    await tester.pumpAndSettle();

    expect(find.byType(HotspotWifiOffPage), findsNothing);
    expect(results, [HotspotWifiOffResult.skipped]);
  });

  testWidgets('close counts as skipping', (tester) async {
    await pumpHostScreen(tester);

    await tester.tap(find.byKey(const ValueKey('hotspot-wifi-off-close')));
    await tester.pumpAndSettle();

    expect(results, [HotspotWifiOffResult.skipped]);
  });

  testWidgets('closes by itself once Wi-Fi goes off', (tester) async {
    await pumpHostScreen(tester);

    host.wifiOn = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(AppMotion.card);

    expect(find.text('Wi-Fi is off'), findsOneWidget);
    expect(find.text('All set'), findsOneWidget);
    expect(find.byType(HotspotWifiOffPage), findsOneWidget);

    await tester.pump(AppMotion.confirmHold);
    await tester.pumpAndSettle();

    expect(find.byType(HotspotWifiOffPage), findsNothing);
    expect(results, [HotspotWifiOffResult.wifiOff]);
  });

  testWidgets('stays up when the host screen moves into the channel', (
    tester,
  ) async {
    await pumpHostScreen(tester);

    // The peer joined: the host screen is replaced by the channel.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const Text('channel')),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(HotspotWifiOffPage), findsOneWidget);

    await tester.tap(find.text('Continue anyway'));
    await tester.pumpAndSettle();

    expect(find.text('channel'), findsOneWidget);
    expect(results, [HotspotWifiOffResult.skipped]);
  });

  testWidgets('reduced motion still shows the page and resolves', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpHostScreen(tester);

    host.wifiOn = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(AppMotion.confirmHold);
    await tester.pumpAndSettle();

    expect(results, [HotspotWifiOffResult.wifiOff]);
  });
}
