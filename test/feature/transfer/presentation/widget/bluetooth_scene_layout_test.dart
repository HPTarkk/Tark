import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/presentation/manager/bluetooth_connect_cubit.dart';
import 'package:tark/feature/transfer/presentation/widget/bluetooth_host_beacon.dart';
import 'package:tark/feature/transfer/presentation/widget/bluetooth_joiner_radar.dart';

void main() {
  for (final phase in ['host', 'search', 'connect', 'location']) {
    testWidgets(
      'Persian $phase stays scrollable with large text on a small phone',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const name = 'گوشی نازنین با نام طولانی برای بررسی نمایش';
        final state = BluetoothConnectState.initial().copyWith(
          myName: name,
          hostDiscoverable: true,
          locationOff: phase == 'location',
          peers: phase == 'search' || phase == 'location'
              ? []
              : const [BluetoothPeer(id: 'aa', name: name, isAppHost: true)],
          connectingPeerId: phase == 'connect' ? 'aa' : null,
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('fa'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: Scaffold(
              appBar: AppBar(),
              body: phase == 'host'
                  ? BluetoothHostBeacon(state: state)
                  : BluetoothJoinerRadar(state: state),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 900));
        await tester.drag(find.byType(Scrollable), const Offset(0, -250));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
