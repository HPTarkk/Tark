import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/presentation/widget/room_reconnect_view.dart';

/// With Wi-Fi off, both phones get told so and are handed the switch.
void main() {
  Widget app(Widget home, {Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );

  RoomReconnectView view(
    RoomReconnectModel model, {
    VoidCallback? onRetry,
    VoidCallback? onTurnOnWifi,
  }) => RoomReconnectView(
    model: model,
    onScan: (_) async => false,
    onSwitch: () {},
    onRetry: onRetry ?? () {},
    onBack: () {},
    onTurnOnWifi: onTurnOnWifi,
  );

  testWidgets('a code that failed with Wi-Fi off offers the Wi-Fi switch '
      'ahead of trying again', (tester) async {
    var wifiTaps = 0;
    var retries = 0;
    await tester.pumpWidget(
      app(
        view(
          const RoomReconnectModel(
            side: RoomReconnectSide.show,
            peerName: 'Sara',
            phase: RoomReconnectPhase.failed,
            message: 'Turn on Wi-Fi',
            wifiOff: true,
          ),
          onRetry: () => retries++,
          onTurnOnWifi: () => wifiTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('room-reconnect-wifi')));
    await tester.tap(find.byKey(const Key('room-reconnect-retry')));
    expect(wifiTaps, 1);
    expect(retries, 1);
    // Wi-Fi first: it is the step that makes the retry work.
    expect(
      tester.getTopLeft(find.byKey(const Key('room-reconnect-wifi'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('room-reconnect-retry'))).dy,
      ),
    );
  });

  testWidgets('a code that failed with Wi-Fi on only offers a retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        view(
          const RoomReconnectModel(
            side: RoomReconnectSide.show,
            peerName: 'Sara',
            phase: RoomReconnectPhase.failed,
          ),
          onTurnOnWifi: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-reconnect-retry')), findsOneWidget);
    expect(find.byKey(const Key('room-reconnect-wifi')), findsNothing);
  });

  for (final locale in const [Locale('en'), Locale('fa')]) {
    testWidgets('the Wi-Fi-off host message reads in ${locale.languageCode}', (
      tester,
    ) async {
      late AppLocalizations s;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              s = AppLocalizations.of(context)!;
              return const SizedBox();
            },
          ),
          locale: locale,
        ),
      );
      expect(s.reconnect_host_wifi_off, isNotEmpty);
      expect(s.reconnect_scan_wifi_off('Sara'), contains('Sara'));
      expect(s.reconnect_scan_no_code_yet('Sara'), contains('Sara'));
      expect(s.reconnect_turn_on_wifi, isNotEmpty);
    });
  }
}
