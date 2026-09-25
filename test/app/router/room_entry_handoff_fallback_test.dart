import 'dart:async';
import 'dart:convert';

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_control_session_registry.dart';
import 'package:tark/feature/room/data/proximity/room_proximity_join_carrier.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_invitation.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_pre_live_announcer.dart';
import 'package:tark/feature/transfer/data/bluetooth/classic_bluetooth_engine.dart';
import 'package:tark/feature/transfer/data/bluetooth/length_prefixed_framer.dart';
import 'package:tark/feature/transfer/data/service/room_proximity_control_channel.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_connection_state.dart';
import 'package:tark/feature/transfer/domain/entity/bluetooth_peer.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/bluetooth_transport.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/repository/wifi_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// A Bluetooth hand-off that goes quiet must not leave either phone on a bare
/// spinner. After a few seconds the hosting phone shows its code and the
/// joining phone opens its camera, so one scan still connects them.
void main() {
  final getIt = GetIt.instance;
  final localId = RoomMemberId('111111111111111111111111');
  final peerId = RoomMemberId('222222222222222222222222');
  const roomId = RoomId('0123456789abcdef0123456789abcdef');
  const invitationId = '0123456789abcdef0123456789abcdef';
  const credentials = HotspotCredentials(
    ssid: 'DIRECT-tark',
    passphrase: 'room-secret',
  );

  final invitation = RoomInvitation(
    version: RoomInvitation.currentVersion,
    roomId: roomId,
    invitationId: invitationId,
    secret: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    kind: RoomInvitationKind.trustedMembership,
    issuedAt: DateTime.utc(2026, 9, 12),
    expiresAt: DateTime.utc(2026, 9, 13),
    singleUse: false,
    displayCode: roomInviteDisplayCode(roomId, invitationId),
  );

  _FakeModeStore? modeStore;

  tearDown(() async {
    modeStore = null;
    await RoomProximityControlSessionRegistry.instance.clear();
    await getIt.reset();
  });

  SavedRoom room() {
    final now = DateTime.utc(2026, 9, 5, 7);
    return SavedRoom(
      room: Room(
        id: roomId,
        name: 'Night ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
          RoomMember(
            id: peerId,
            displayName: 'Rider two',
            joinedAt: now.add(const Duration(seconds: 1)),
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localId,
        canManageInvites: true,
      ),
    );
  }

  /// A Bluetooth link to the other phone that is up but will never deliver.
  Future<_FakeEngine> linked({required bool issuer}) async {
    final engine = _FakeEngine();
    final channel = RoomProximityControlChannel(engine: engine);
    await channel.host(rendezvousToken: invitationId);
    await RoomProximityControlSessionRegistry.instance.adopt(
      roomId: roomId,
      invitation: invitation,
      channel: channel,
      issuer: issuer,
    );
    if (issuer) {
      // The joiner spoke once when it connected, then went quiet.
      engine.addEnvelope(
        RoomProximityEnvelope(
          kind: 'hello',
          roomId: roomId.value,
          requestId: '0' * 32,
          joinEpoch: invitationId,
          payload: '{}',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return engine;
  }

  Future<_FakeJoiner> pumpEntry(
    WidgetTester tester, {
    required LiveLinkSnapshot links,
    HotspotJoinResult joinResult = HotspotJoinResult.declined,
    ValueNotifier<bool>? wifi,
    TransferMode? pinned,
    _FakeBluetooth? bluetooth,
  }) async {
    const identityChannel = MethodChannel('tark/room_identity_secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      identityChannel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        identityChannel,
        null,
      ),
    );
    final joiner = _FakeJoiner(joinResult);
    getIt.registerLazySingleton<RoomRepository>(
      () => _FakeRoomRepository(room()),
    );
    getIt.registerLazySingleton<LiveLinkProbe>(() => _FakeProbe(links));
    getIt.registerLazySingleton<TransferModeStore>(
      () => modeStore = _FakeModeStore(TransferMode.wifi, pinned: pinned),
    );
    if (bluetooth != null) {
      getIt.registerLazySingleton<BluetoothTransport>(() => bluetooth);
    }
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
    getIt.registerLazySingleton<WifiTransferRepository>(_FakeWifi.new);
    getIt.registerLazySingleton<ChannelMembership>(ChannelMembership.new);
    getIt.registerLazySingleton<HotspotHost>(() => _FakeHotspotHost(wifi));
    getIt.registerLazySingleton<HotspotLinkKeeper>(_FakeKeeper.new);
    getIt.registerLazySingleton<HotspotJoiner>(() => joiner);

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => const Scaffold()),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, _) => RoomBoundWalkieEntry(
            wifiCheck: wifi != null,
            prepareHost: () async => credentials,
          ),
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
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return joiner;
  }

  /// Lets every attempt in flight run out, so no timer outlives the test.
  /// Closing an attempt also closes the fake Bluetooth link, which lives in
  /// the real zone (see [linked]); give that real time, then let the fake
  /// clock pick the result up.
  Future<void> settleTeardown(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets every attempt in flight run out, so no timer outlives the test.
  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  const hosting = LiveLinkSnapshot(
    wifi: false,
    hostingHotspot: true,
    bluetooth: false,
  );
  const onWifi = LiveLinkSnapshot(
    wifi: true,
    hostingHotspot: false,
    bluetooth: false,
  );

  group('Bluetooth chosen in settings', () {
    testWidgets('the phone that showed the invite hosts over Bluetooth', (
      tester,
    ) async {
      await tester.runAsync(() => linked(issuer: true));
      final bluetooth = _FakeBluetooth();
      await pumpEntry(
        tester,
        links: onWifi,
        pinned: TransferMode.bluetooth,
        bluetooth: bluetooth,
      );
      await start(tester);
      await tester.pump(const Duration(seconds: 2));
      await settleTeardown(tester);

      // No hotspot: the invite's Bluetooth link is swapped for the audio one.
      expect(bluetooth.hosted, 1);
      expect(modeStore?.writes, contains(TransferMode.bluetooth));
      expect(modeStore?.writes, isNot(contains(TransferMode.hotspot)));
      expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
      await drain(tester);
      await settleTeardown(tester);
    });
  });

  group('hosting phone', () {
    testWidgets('shows its code once the hand-off has gone quiet', (
      tester,
    ) async {
      await tester.runAsync(() => linked(issuer: true));
      await pumpEntry(tester, links: hosting);
      await start(tester);

      // A normal hand-off gets its few seconds untouched.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
      expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byKey(const ValueKey('room-reconnect-show')), findsOneWidget);
      expect(find.text('Waiting for Rider two…'), findsOneWidget);
      // It is the same network the hand-off sent, so either path joins it.
      expect(find.byKey(const Key('room-reconnect-switch')), findsNothing);

      // And it still ends: nobody came, so it says so and offers a retry.
      await tester.pump(const Duration(seconds: 60));
      await settleTeardown(tester);
      expect(find.byKey(const Key('room-reconnect-retry')), findsOneWidget);
      await drain(tester);
      await settleTeardown(tester);
    });
  });

  group('joining phone', () {
    testWidgets('opens the camera once the hand-off has gone quiet', (
      tester,
    ) async {
      await tester.runAsync(() => linked(issuer: false));
      await pumpEntry(tester, links: onWifi);
      await start(tester);

      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(QrScannerSurface), findsNothing);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.byType(QrScannerSurface), findsOneWidget);
      expect(
        find.text("Point the camera at the code on Rider two's phone."),
        findsOneWidget,
      );
      await drain(tester);
    });

    testWidgets('a scanned code is joined in place of the Bluetooth one', (
      tester,
    ) async {
      await tester.runAsync(() => linked(issuer: false));
      final joiner = await pumpEntry(tester, links: onWifi);
      await start(tester);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump();

      final surface = tester.widget<QrScannerSurface>(
        find.byType(QrScannerSurface),
      );
      unawaited(
        surface.onCode(
          credentials.qrPayload(
            channel: RoomPreLiveAnnouncer.channelFor(roomId),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(joiner.joined, [credentials]);
      await drain(tester);
    });

    testWidgets('Wi-Fi off asks for Wi-Fi, then joins with the same details', (
      tester,
    ) async {
      final engine = (await tester.runAsync(() => linked(issuer: false)))!;
      final wifi = ValueNotifier(false);
      final joiner = await pumpEntry(
        tester,
        links: onWifi,
        joinResult: HotspotJoinResult.wifiOff,
        wifi: wifi,
      );
      await start(tester);

      // The other phone's details arrive over Bluetooth. Sent from the zone
      // the fake link lives in, or its stream never delivers under pump().
      await tester.runAsync(() async {
        engine.addEnvelope(
          RoomProximityEnvelope(
            kind: 'transportCredentials',
            roomId: roomId.value,
            requestId: '${'0' * 31}1',
            joinEpoch: invitationId,
            payload: jsonEncode({
              'ssid': credentials.ssid,
              'passphrase': credentials.passphrase,
              'security': credentials.security,
            }),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('room-reconnect-wifi')), findsOneWidget);
      expect(joiner.joined, [credentials]);

      joiner.result = HotspotJoinResult.joined;
      wifi.value = true;
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // No second scan: the details already in hand are joined again.
      expect(joiner.joined, [credentials, credentials]);
      await drain(tester);
    });
  });
}

class _FakeJoiner implements HotspotJoiner {
  _FakeJoiner(this.result);

  HotspotJoinResult result;
  final joined = <HotspotCredentials>[];

  @override
  Future<HotspotJoinResult> join(HotspotCredentials credentials) async {
    joined.add(credentials);
    return result;
  }

  @override
  Future<bool> enableWifi() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeWifi implements WifiTransferRepository {
  int listens = 0;
  int stops = 0;
  final presences = <String>[];

  @override
  Stream<WakiPacket> startListening() {
    listens++;
    return const Stream<WakiPacket>.empty();
  }

  @override
  Future<Either<Failure, void>> sendPresence(
    String senderName,
    bool isTalking, {
    bool isLeaving = false,
  }) async {
    presences.add(senderName);
    return const Right(null);
  }

  @override
  void stopConnection() => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeTransfer implements TransferRepository {
  final _health = StreamController<ConnectionHealth>.broadcast();

  @override
  SessionRole get sessionRole => SessionRole.unknown;

  @override
  Stream<ConnectionHealth> connect() => _health.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeHotspotHost implements HotspotHost {
  _FakeHotspotHost(this.wifi);

  final ValueNotifier<bool>? wifi;

  @override
  bool get isHosting => false;

  @override
  Future<HotspotWifiAdvice> wifiAdvice() async => HotspotWifiAdvice(
    wifiEnabled: wifi?.value ?? true,
    concurrent: true,
    canPanel: true,
  );

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeKeeper implements HotspotLinkKeeper {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeProbe implements LiveLinkProbe {
  _FakeProbe(this.links);

  final LiveLinkSnapshot links;

  @override
  Future<LiveLinkSnapshot> read() async => links;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

class _FakeModeStore implements TransferModeStore {
  _FakeModeStore(this._mode, {this.pinned});

  TransferMode _mode;
  final TransferMode? pinned;
  final writes = <TransferMode>[];

  @override
  TransferMode get mode => _mode;

  @override
  TransferMode? get pinnedMode => pinned;

  @override
  Future<void> setMode(TransferMode mode) async {
    writes.add(mode);
    _mode = mode;
  }

  @override
  Stream<TransferMode> get modeChanges => const Stream<TransferMode>.empty();

  @override
  Stream<TransferMode?> get pinChanges => const Stream<TransferMode?>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {}
}

class _FakeRoomRepository implements RoomRepository {
  _FakeRoomRepository(this._room);

  final SavedRoom _room;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<RoomId?> selectedRoomId() async => _room.room.id;

  @override
  Future<SavedRoom?> get(RoomId id) async => id == _room.room.id ? _room : null;

  @override
  Future<List<SavedRoom>> list({bool includeArchived = false}) async => [_room];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeEngine extends ClassicBluetoothEngine {
  final incoming = StreamController<Uint8List>.broadcast();
  final connected = StreamController<String>.broadcast();
  final errors = StreamController<String>.broadcast();
  final closed = StreamController<void>.broadcast();
  final writes = <Uint8List>[];

  @override
  Stream<Uint8List> get input => incoming.stream;

  @override
  Stream<String> get onPeerConnected => connected.stream;

  @override
  Stream<String> get onError => errors.stream;

  @override
  Stream<void> get onClosed => closed.stream;

  @override
  Future<bool> requestDiscoverable({int durationSeconds = 300}) async => true;

  @override
  Future<void> startHosting({String name = 'tark'}) async {}

  @override
  Stream<BluetoothPeer> scanForHosts() => const Stream.empty();

  @override
  void cancelDiscovery() {}

  @override
  Future<void> write(Uint8List bytes) async {
    writes.add(Uint8List.fromList(bytes));
  }

  void addEnvelope(RoomProximityEnvelope envelope) {
    incoming.add(
      frameMessage(Uint8List.fromList(utf8.encode(envelope.encode()))),
    );
  }

  @override
  Future<void> dispose() async {
    await incoming.close();
    await connected.close();
    await errors.close();
    await closed.close();
  }
}

class _FakeBluetooth implements BluetoothTransport {
  final _states = StreamController<BluetoothConnectionState>.broadcast();
  int hosted = 0;

  @override
  Stream<BluetoothConnectionState> get connectionState => _states.stream;

  @override
  BluetoothConnectionState get currentConnectionState =>
      BluetoothConnectionState.hosting;

  @override
  Future<void> startHosting() async => hosted++;

  @override
  void reset() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
