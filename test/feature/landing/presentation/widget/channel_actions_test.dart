import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/landing/presentation/widget/channel_actions.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  // Android, no network: both intents fall to the hotspot rung.
  const androidNoWifi = LinkConditions(
    hasWifi: false,
    canHostHotspot: true,
    canJoinHotspot: true,
    bluetoothSupported: true,
  );
  // Android, on a network: hotspot still leads (it's the default), but a
  // network is right there for the "On the same Wi-Fi?" link to offer.
  const androidOnWifi = LinkConditions(
    hasWifi: true,
    canHostHotspot: true,
    canJoinHotspot: true,
    bluetoothSupported: true,
  );
  // Can bridge nothing itself, but has a network — the one shape that still
  // resolves to a shared-network plan under the new ladder.
  const bareOnWifi = LinkConditions(
    hasWifi: true,
    canHostHotspot: false,
    canJoinHotspot: false,
    bluetoothSupported: false,
  );

  late List<ChannelPlan> tapped;
  late int differentNetworkTaps;
  late int sameWifiTaps;

  setUp(() {
    tapped = [];
    differentNetworkTaps = 0;
    sameWifiTaps = 0;
  });

  Future<AppLocalizations> pump(
    WidgetTester tester,
    LinkConditions conditions, {
    bool enabled = true,
    Locale locale = const Locale('en'),
  }) async {
    late AppLocalizations strings;
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          // Persian has no Cupertino translations without this one, and the
          // framework reports that as a caught exception — which the overflow
          // check below would otherwise read as a layout failure.
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              strings = AppLocalizations.of(context)!;
              return ChannelActions(
                createPlan: TransportAdvisor.plan(
                  ChannelIntent.create,
                  conditions,
                ),
                joinPlan: TransportAdvisor.plan(ChannelIntent.join, conditions),
                pulse: 0,
                enabled: enabled,
                onTap: tapped.add,
                onDifferentNetwork: () => differentNetworkTaps++,
                onSameWifi: () => sameWifiTaps++,
                hasWifi: conditions.hasWifi,
              );
            },
          ),
        ),
      ),
    );
    return strings;
  }

  group('ChannelActions', () {
    testWidgets('offers both sides of a pairing', (tester) async {
      final s = await pump(tester, androidOnWifi);
      expect(find.text(s.channel_create), findsOneWidget);
      expect(find.text(s.channel_join), findsOneWidget);
    });

    // The whole point of naming the route under each button: a rider who taps
    // START and watches a hotspot come up has to be able to tell that was the
    // plan rather than a malfunction.
    testWidgets('each action says which route it will take', (tester) async {
      final s = await pump(tester, androidNoWifi);
      expect(find.text(s.channel_via_own_hotspot), findsOneWidget);
      expect(find.text(s.channel_via_scan_code), findsOneWidget);
    });

    testWidgets('on a shared network both say so', (tester) async {
      final s = await pump(tester, bareOnWifi);
      expect(find.text(s.channel_via_shared_network), findsNWidgets(2));
    });

    testWidgets('tapping hands back the plan, intent and all', (tester) async {
      final s = await pump(tester, androidNoWifi);
      await tester.tap(find.text(s.channel_join));
      await tester.pump();
      expect(tapped.single.intent, ChannelIntent.join);
      expect(tapped.single.mode, TransferMode.hotspot);
    });

    testWidgets('a disabled screen commits to nothing', (tester) async {
      final s = await pump(tester, androidOnWifi, enabled: false);
      await tester.tap(find.text(s.channel_create));
      await tester.tap(find.text(s.channel_join));
      await tester.pump();
      expect(tapped, isEmpty);
    });

    // Guest's far end is a browser, so a join button here would lead nowhere.
    testWidgets('a guest pin drops the join side entirely', (tester) async {
      final s = await pump(
        tester,
        const LinkConditions(
          hasWifi: true,
          canHostHotspot: true,
          canJoinHotspot: true,
          bluetoothSupported: true,
          pinned: TransferMode.guest,
        ),
      );
      expect(find.text(s.channel_create), findsOneWidget);
      expect(find.text(s.channel_join), findsNothing);
    });

    // Each action carries two lines of text next to an icon, and the Persian
    // route lines are the longest strings in the set — the combination that
    // overflows if it is going to. 320 logical pixels less the page's own 24pt
    // gutters is the narrowest phone the app is built for.
    group('fits a small phone', () {
      for (final locale in [const Locale('en'), const Locale('fa')]) {
        testWidgets('in ${locale.languageCode}', (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          // No network: the longest route lines, no way-out link at all.
          await pump(tester, androidNoWifi, locale: locale);
          expect(tester.takeException(), isNull);
          // Hotspot default with a network in reach: the "same Wi-Fi?" link.
          await pump(tester, androidOnWifi, locale: locale);
          expect(tester.takeException(), isNull);
          // Shared-network plan: the "different network?" link.
          await pump(tester, bareOnWifi, locale: locale);
          expect(tester.takeException(), isNull);
        });
      }
    });

    group('the different-network way out', () {
      testWidgets('is offered while the plan assumes one network', (
        tester,
      ) async {
        final s = await pump(tester, bareOnWifi);
        await tester.tap(find.text(s.channel_different_network));
        await tester.pump();
        expect(differentNetworkTaps, 1);
      });

      testWidgets('is gone once the plan is the hotspot itself', (
        tester,
      ) async {
        final s = await pump(tester, androidNoWifi);
        expect(find.text(s.channel_different_network), findsNothing);
      });
    });

    group('the same-wifi way out', () {
      testWidgets('is offered while the default assumes a hotspot but a '
          'network is in reach', (tester) async {
        final s = await pump(tester, androidOnWifi);
        await tester.tap(find.text(s.channel_same_wifi));
        await tester.pump();
        expect(sameWifiTaps, 1);
      });

      testWidgets('is gone with no network to fall back to', (tester) async {
        final s = await pump(tester, androidNoWifi);
        expect(find.text(s.channel_same_wifi), findsNothing);
      });

      testWidgets('is gone once the plan is already the shared network', (
        tester,
      ) async {
        final s = await pump(tester, bareOnWifi);
        expect(find.text(s.channel_same_wifi), findsNothing);
      });
    });
  });
}
