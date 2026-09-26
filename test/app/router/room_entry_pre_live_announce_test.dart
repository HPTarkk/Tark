import 'dart:async';

import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/error/failure.dart';
import 'package:tark/core/identity/channel_id.dart';
import 'package:tark/core/identity/channel_membership.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/room/domain/service/room_pre_live_announcer.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/entity/waki_packet.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/repository/wifi_transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// Regression for "the Room is created and joined, but the phones never
/// connect". The readiness gate only lets a Room go live after a peer's signed
/// proof arrives over Wi-Fi, and Wi-Fi only exchanges proofs with peers it has
/// heard. Before the fix nothing bound the socket or said hello until the live
/// screen opened — which the gate withholds — so no attempt could ever pass.
void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  SavedRoom room() {
    final localId = RoomMemberId('111111111111111111111111');
    final peerId = RoomMemberId('222222222222222222222222');
    final now = DateTime.utc(2026, 9, 5, 7);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
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

  testWidgets('Start announces on Wi-Fi while waiting for peer proof, then '
      'releases the socket when nobody answers', (tester) async {
    // No secure identity on this device: the binding opens without failover,
    // which is all the gate needs to run.
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
    final wifi = _FakeWifi();
    // Left over from an earlier session, as the scanning phone's would be.
    final membership = ChannelMembership()..join(const ChannelId(0x00ABCD));
    getIt.registerLazySingleton<RoomRepository>(
      () => _FakeRoomRepository(room()),
    );
    getIt.registerLazySingleton<LiveLinkProbe>(
      () => _FakeProbe(
        const LiveLinkSnapshot(
          wifi: true,
          hostingHotspot: false,
          bluetooth: false,
        ),
      ),
    );
    getIt.registerLazySingleton<TransferModeStore>(
      () => _FakeModeStore(TransferMode.wifi),
    );
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
    getIt.registerLazySingleton<WifiTransferRepository>(() => wifi);
    getIt.registerLazySingleton<ChannelMembership>(() => membership);
    getIt.registerLazySingleton<HotspotHost>(_FakeHotspotHost.new);
    getIt.registerLazySingleton<HotspotLinkKeeper>(_FakeKeeper.new);

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => const Scaffold()),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, _) => RoomBoundWalkieEntry.buildPage(),
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
    expect(wifi.listens, 0, reason: 'opening the lobby starts nothing');

    // Start sits below Invite and can be under the fold.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Every member lands on the Room's own channel, whatever a previous
    // session left behind.
    expect(
      membership.current.value,
      RoomPreLiveAnnouncer.channelFor(room().room.id).value,
    );
    expect(wifi.listens, 1);
    expect(wifi.presences, isNotEmpty);
    expect(wifi.presences.first, 'Rider one');
    expect(wifi.stops, 0);

    // Nobody answers: the gate times out and the attempt gives the socket
    // back instead of leaving it pinging an empty network.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    final sent = wifi.presences.length;
    expect(wifi.stops, 1);
    await tester.pump(const Duration(seconds: 3));
    expect(wifi.presences.length, sent);
    expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);
  });
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
  @override
  bool get isHosting => false;

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
  _FakeModeStore(this._mode);

  TransferMode _mode;
  final writes = <TransferMode>[];

  @override
  TransferMode get mode => _mode;

  @override
  TransferMode? get pinnedMode => null;

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
