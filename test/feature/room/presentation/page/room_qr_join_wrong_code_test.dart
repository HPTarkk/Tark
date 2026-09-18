import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_qr_join_page.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';

/// What the Room's one-scan scanner does with a code that is not a Room
/// invite.
///
/// Reported from the field as **"That invite is invalid or expired"** while
/// pointing the camera at the host's hotspot QR — a code that was neither
/// invalid nor expired, and that the phone could have acted on. The decision
/// lives in `onCode`, so that is what these drive; the camera itself is not
/// part of the question.
void main() {
  const host = HotspotCredentials(
    ssid: 'AndroidShare_1234',
    passphrase: 'ridewithme',
  );

  late List<Object?> handed;
  late List<String> visited;

  Future<QrScannerSurface> pumpScanner(WidgetTester tester) async {
    handed = [];
    visited = [];
    final router = GoRouter(
      initialLocation: AppRoutes.roomQrJoinPath,
      routes: [
        GoRoute(
          path: AppRoutes.roomQrJoinPath,
          builder: (_, _) => RoomQrJoinPage(cubit: _FakeRoomList()),
        ),
        GoRoute(
          path: AppRoutes.wifiHotspotPath,
          builder: (_, state) {
            handed.add(state.extra);
            visited.add(state.uri.toString());
            return const Scaffold(
              key: Key('hotspot-page'),
              body: SizedBox.shrink(),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return tester.widget<QrScannerSurface>(find.byType(QrScannerSurface));
  }

  String? errorOn(WidgetTester tester) =>
      tester.widget<QrScannerSurface>(find.byType(QrScannerSurface)).errorText;

  testWidgets('the host hotspot code is followed, not blamed', (tester) async {
    final surface = await pumpScanner(tester);
    final payload = host.qrPayload(channel: ClientChannel.code);

    // The scanner keeps its frame locked: this page is leaving, and re-arming
    // a camera behind a route that is on its way out is how a scan gets read
    // twice.
    expect(await surface.onCode(payload), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('hotspot-page')), findsOneWidget);
    // Handed over rather than re-scanned. The camera has already been held up
    // to this code once.
    expect(handed.single, payload);
  });

  testWidgets('and the passphrase never reaches the URL', (tester) async {
    final surface = await pumpScanner(tester);
    await surface.onCode(host.qrPayload(channel: ClientChannel.code));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // `extra` rather than a query parameter, and this is the whole reason
    // why: the payload carries the network's passphrase. The URI the route
    // was actually reached by is the only thing that can say so — and it is
    // asserted to be the bridge's own route first, so this cannot pass by
    // reading an empty string.
    final location = visited.single;
    expect(location, contains(AppRoutes.wifiHotspotPath));
    expect(location, isNot(contains(host.passphrase)));
    expect(location, isNot(contains(host.ssid)));
    // And the payload still got there.
    expect(handed.single, isA<String>());
  });

  testWidgets('a code that is ours but will not decode still says invite', (
    tester,
  ) async {
    final surface = await pumpScanner(tester);

    expect(await surface.onCode('tark-room:AwGrq6urq6ur'), isFalse);
    await tester.pump();

    expect(errorOn(tester), 'That invite is invalid or expired.');
    // Nowhere to send it, so the camera re-arms rather than stranding the
    // user on a dead viewfinder.
    expect(find.byKey(const Key('hotspot-page')), findsNothing);
  });

  testWidgets('and something that was never ours says that instead', (
    tester,
  ) async {
    final surface = await pumpScanner(tester);

    expect(await surface.onCode('https://example.com'), isFalse);
    await tester.pump();

    // The old message named two causes and both were wrong here. A bus
    // ticket is not an expired invite.
    expect(errorOn(tester), isNot('That invite is invalid or expired.'));
    expect(errorOn(tester), contains("isn't a Tarkk one"));
  });
}

/// A channel code that parses, kept here so the payload under test is the one
/// a host actually shows: network *and* conversation in a single QR.
abstract final class ClientChannel {
  static final code = ChannelId.parse('A83F21')!;
}

class _FakeRoomList implements RoomListCubit {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
