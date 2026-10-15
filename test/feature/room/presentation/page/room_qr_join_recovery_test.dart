import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/widget/connection_journey.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/page/room_qr_join_page.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';

/// A one-scan join whose network half fails: explained, retried without the
/// camera, and — once retrying is not the better bet — turned round so this
/// phone (a member by now) shows its own code instead.
void main() {
  const host = HotspotCredentials(
    ssid: 'AndroidShare_1234',
    passphrase: 'ridewithme',
  );
  const roomId = RoomId('0123456789abcdef0123456789abcdef');

  late List<String> visited;
  late List<RoomId> swappedTo;

  tearDown(() => GetIt.instance.reset());

  Future<QrScannerSurface> pumpScanner(
    WidgetTester tester, {
    required List<HotspotJoinResult> results,
    bool canShowCode = true,
    bool customSwap = true,
    List<int>? attempts,
  }) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    visited = [];
    swappedTo = [];
    var call = 0;
    final router = GoRouter(
      initialLocation: AppRoutes.roomQrJoinPath,
      routes: [
        GoRoute(
          path: AppRoutes.roomQrJoinPath,
          builder: (_, _) => RoomQrJoinPage(
            cubit: _FakeRoomList(),
            canShowCode: canShowCode,
            hotspotJoin: (_) async {
              attempts?.add(call);
              return results[(call++).clamp(0, results.length - 1)];
            },
            onShowCodeInstead: customSwap
                ? (room) async => swappedTo.add(room)
                : null,
          ),
        ),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, state) {
            visited.add(state.uri.toString());
            return const Scaffold(key: Key('walkie-page'));
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

  Future<void> scan(WidgetTester tester, QrScannerSurface surface) async {
    expect(
      await surface.onCode(host.qrPayload(roomInvite: _bundle().encode())),
      isTrue,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  bool isPrimary(WidgetTester tester, String key) => find
      .descendant(
        of: find.byKey(Key(key)),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      )
      .evaluate()
      .isNotEmpty;

  testWidgets('a first ordinary failure keeps Try again first, offers the '
      'swap second, and Try again needs no camera', (tester) async {
    final attempts = <int>[];
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.wifiOff, HotspotJoinResult.joined],
      attempts: attempts,
    );
    await scan(tester, surface);

    expect(find.text("Couldn't connect"), findsOneWidget);
    expect(
      find.text('Wi-Fi is off on this phone. Turn it on, then try again.'),
      findsOneWidget,
    );
    expect(isPrimary(tester, 'room-join-retry'), isTrue);
    expect(find.byKey(const Key('room-join-show-code')), findsOneWidget);
    expect(isPrimary(tester, 'room-join-show-code'), isFalse);
    expect(find.byKey(const Key('room-join-scan-again')), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-join-retry')));
    await tester.pump();
    // The scene goes back to linking in place; the camera does not reopen.
    expect(find.byType(QrScannerSurface), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, [0, 1]);
    expect(find.byKey(const Key('walkie-page')), findsOneWidget);
    expect(visited.last, '${AppRoutes.walkiePath}?ride=true&start=true');
  });

  testWidgets('the second failure makes "Show my code instead" the way '
      'forward, and says why', (tester) async {
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.wifiOff],
    );
    await scan(tester, surface);
    await tester.tap(find.byKey(const Key('room-join-retry')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(isPrimary(tester, 'room-join-show-code'), isTrue);
    expect(isPrimary(tester, 'room-join-retry'), isFalse);
    expect(find.textContaining("You're already in the room"), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-join-show-code')));
    await tester.pump();
    expect(swappedTo, [roomId]);
  });

  testWidgets('a declined join swaps first straight away', (tester) async {
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.declined],
    );
    await scan(tester, surface);

    expect(
      find.textContaining("This phone couldn't get onto their phone's hotspot"),
      findsOneWidget,
    );
    expect(isPrimary(tester, 'room-join-show-code'), isTrue);
  });

  testWidgets('a phone that cannot share a connection is never offered '
      'the swap', (tester) async {
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.declined],
      canShowCode: false,
    );
    await scan(tester, surface);

    expect(find.byKey(const Key('room-join-show-code')), findsNothing);
    expect(isPrimary(tester, 'room-join-retry'), isTrue);
  });

  testWidgets('by default the swap opens the Room showing this phone code', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.declined],
      customSwap: false,
    );
    await scan(tester, surface);
    await tester.tap(find.byKey(const Key('room-join-show-code')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(visited.last, '${AppRoutes.walkiePath}?rejoin=true');
    final prefs = await SharedPreferences.getInstance();
    final ticket = prefs.getString(SettingsKeys.roomRejoinTicket)!;
    expect(ticket, contains('"side":"host"'));
    expect(ticket, contains('"mode":"hotspot"'));
    expect(ticket, contains(roomId.value));
  });

  testWidgets('the failed scene is the hotspot one', (tester) async {
    final surface = await pumpScanner(
      tester,
      results: [HotspotJoinResult.locationOff],
    );
    await scan(tester, surface);
    final journey = tester.widget<ConnectionJourney>(
      find.byType(ConnectionJourney),
    );
    expect(journey.stage, JourneyStage.failed);
    expect(journey.link, JourneyLink.hotspot);
  });
}

class _FakeRoomList implements RoomListCubit {
  @override
  Future<bool> needsMoreRoomsAccess({RoomId? existingRoom}) async => false;
  @override
  Future<bool> joinDirect(
    RoomDirectJoinBundle bundle, {
    String? localDisplayName,
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

RoomDirectJoinBundle _bundle() {
  const roomId = RoomId('0123456789abcdef0123456789abcdef');
  final memberId = RoomMemberId('111111111111111111111111');
  final now = DateTime.now().toUtc();
  final key = List<int>.filled(32, 1);
  return RoomDirectJoinBundle(
    memberId: memberId,
    snapshot: RoomAcceptedJoinSnapshot(
      roomId: roomId,
      roomName: 'Ride',
      roomCreatedAt: now,
      roomUpdatedAt: now,
      members: [
        RoomAcceptedJoinMember(
          memberId: memberId,
          kind: RoomMemberKind.member,
          joinedAt: now,
          displayName: 'Rider',
        ),
      ],
    ),
    memberKeyPair: RoomMemberTransportKeyPair(privateKey: key, publicKey: key),
    certificate: RoomMemberTransportCertificate(
      roomId: roomId,
      memberId: memberId,
      memberPublicKey: key,
      issuerPublicKey: key,
      issuerSignature: List<int>.filled(64, 2),
    ),
    expiresAt: now.add(const Duration(hours: 1)),
  );
}
