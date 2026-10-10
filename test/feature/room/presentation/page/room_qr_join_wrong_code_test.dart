import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/presentation/manager/room_list_cubit.dart';
import 'package:tark/feature/room/presentation/bluetooth_invite_joiner.dart';
import 'package:tark/feature/room/presentation/page/room_qr_join_page.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_accepted_join_snapshot.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/entity/room_invite_link.dart';
import 'package:tark/feature/room/domain/service/room_member_transport_identity.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';

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

  tearDown(() => GetIt.instance.reset());

  Future<QrScannerSurface> pumpScanner(
    WidgetTester tester, {
    BluetoothInviteJoiner? bluetoothJoiner,
  }) async {
    handed = [];
    visited = [];
    final router = GoRouter(
      initialLocation: AppRoutes.roomQrJoinPath,
      routes: [
        GoRoute(
          path: AppRoutes.roomQrJoinPath,
          builder: (_, _) => RoomQrJoinPage(
            cubit: _FakeRoomList(),
            bluetoothJoiner: bluetoothJoiner,
          ),
        ),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, state) {
            visited.add(state.uri.toString());
            return const Scaffold(key: Key('walkie-page'));
          },
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

  testWidgets('network setup errors reject the scan and allow another try', (
    tester,
  ) async {
    final joiner = _FailingJoiner();
    GetIt.instance.registerSingleton<HotspotJoiner>(joiner);
    final surface = await pumpScanner(tester);
    const roomId = RoomId('0123456789abcdef0123456789abcdef');
    final memberId = RoomMemberId('111111111111111111111111');
    final now = DateTime.now().toUtc();
    final key = List<int>.filled(32, 1);
    final bundle = RoomDirectJoinBundle(
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
      memberKeyPair: RoomMemberTransportKeyPair(
        privateKey: key,
        publicKey: key,
      ),
      certificate: RoomMemberTransportCertificate(
        roomId: roomId,
        memberId: memberId,
        memberPublicKey: key,
        issuerPublicKey: key,
        issuerSignature: List<int>.filled(64, 2),
      ),
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final payload = host.qrPayload(roomInvite: bundle.encode());

    expect(await surface.onCode(payload), isFalse);
    await tester.pump();
    expect(errorOn(tester), isNotNull);
    expect(await surface.onCode(payload), isFalse);
    expect(joiner.attempts, 2);
    expect(find.byKey(const Key('hotspot-page')), findsNothing);
  });

  testWidgets(
    'a Bluetooth invite saves membership, then looks for the host by radio',
    (tester) async {
      final joiner = _FakeBluetoothJoiner(BluetoothInviteJoinResult.notFound);
      final surface = await pumpScanner(tester, bluetoothJoiner: joiner);
      final room = _FakeRoomList.instance;
      final link = BluetoothInviteLink.fresh();
      final payload = link.payload(_bundle().encode());

      // No phone is advertising in this harness, so the find fails — and
      // says so in the words a rider can act on, with membership already
      // saved so a second scan only has to find the phone.
      expect(await tester.runAsync(() => surface.onCode(payload)), isFalse);
      await tester.pump();
      expect(room.joined, 1);
      expect(
        errorOn(tester),
        "Couldn't find their phone. Keep the invite open on it, stay close, "
        'and scan again.',
      );
      expect(find.byKey(const Key('hotspot-page')), findsNothing);
      expect(joiner.tokens, [link.token]);
    },
  );

  testWidgets('a Bluetooth invite that links goes straight into the call', (
    tester,
  ) async {
    final joiner = _FakeBluetoothJoiner(BluetoothInviteJoinResult.joined);
    final surface = await pumpScanner(tester, bluetoothJoiner: joiner);
    final payload = BluetoothInviteLink.fresh().payload(_bundle().encode());

    expect(await tester.runAsync(() => surface.onCode(payload)), isTrue);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('walkie-page')), findsOneWidget);
    expect(visited.last, '${AppRoutes.walkiePath}?ride=true&start=true');
  });

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

  String inviteShaped(int version) =>
      'tark-room:${base64Url.encode(utf8.encode(jsonEncode({'v': version, 'roomId': '0123456789abcdef0123456789abcdef', 'invitationId': 'fedcba9876543210fedcba9876543210', 'expiresAt': '2020-01-01T00:00:00.000Z'}))).replaceAll('=', '')}';

  testWidgets('an expired or damaged Room invite is called an invite', (
    tester,
  ) async {
    final surface = await pumpScanner(tester);

    expect(await surface.onCode(inviteShaped(1)), isFalse);
    await tester.pump();

    // Not "isn't a Tarkk one": that sent people hunting for another QR on
    // the host's phone when the fix was a fresh invite.
    expect(errorOn(tester), 'That invite is invalid or expired.');
  });

  testWidgets('a malformed direct-join version is called an invalid invite', (
    tester,
  ) async {
    final surface = await pumpScanner(tester);

    expect(await surface.onCode(inviteShaped(2)), isFalse);
    await tester.pump();

    // DirectJoin v2/v3 are binary records. A JSON body carrying v=2 is not an
    // invite from another app version; it is simply malformed DirectJoin data.
    expect(errorOn(tester), 'That invite is invalid or expired.');
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
  _FakeRoomList() {
    instance = this;
  }

  /// The one the page under test was built with.
  static late _FakeRoomList instance;

  int joined = 0;

  @override
  Future<bool> needsMoreRoomsAccess({RoomId? existingRoom}) async => false;
  @override
  Future<bool> joinDirect(
    RoomDirectJoinBundle bundle, {
    String? localDisplayName,
  }) async {
    joined++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeBluetoothJoiner implements BluetoothInviteJoiner {
  _FakeBluetoothJoiner(this.result);

  final BluetoothInviteJoinResult result;
  final tokens = <String>[];

  @override
  Future<BluetoothInviteJoinResult> join(BluetoothInviteLink link) async {
    tokens.add(link.token);
    return result;
  }
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

class _FailingJoiner implements HotspotJoiner {
  int attempts = 0;

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    attempts++;
    if (attempts == 1) throw StateError('Native network setup failed');
    return HotspotJoinResult.declined;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
