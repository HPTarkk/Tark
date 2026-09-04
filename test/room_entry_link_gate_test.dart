import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// The gate itself, at the composition root: a Room with nothing carrying it
/// does not open a channel, and the tap that used to do that now goes to the
/// screen that can get a link instead.
///
/// The positive case — a link is up, so the channel opens — is deliberately
/// not here. Reaching it builds the live Walkie surface, which resolves an
/// audio engine and a cubit from a graph this test has no business standing
/// up; the half worth pinning down is the refusal.
void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  SavedRoom room() {
    final localId = RoomMemberId('111111111111111111111111');
    final peerId = RoomMemberId('222222222222222222222222');
    final now = DateTime.utc(2026, 9, 3, 9);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Night ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: localId, displayName: 'Rider one', joinedAt: now),
          RoomMember(id: peerId, displayName: 'Rider two', joinedAt: now),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localId,
        canManageInvites: true,
      ),
    );
  }

  Future<void> pumpEntry(
    WidgetTester tester, {
    required LiveLinkSnapshot links,
    required _FakeModeStore modeStore,
  }) async {
    getIt.registerLazySingleton<RoomRepository>(
      () => _FakeRoomRepository(room()),
    );
    getIt.registerLazySingleton<LiveLinkProbe>(() => _FakeProbe(links));
    getIt.registerLazySingleton<TransferModeStore>(() => modeStore);
    // The binding this entry composes needs all three, and a composition that
    // cannot be built at all skips the lobby entirely — which would make the
    // gate untestable by making it unreachable.
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
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
        GoRoute(
          path: AppRoutes.wifiHotspotPath,
          builder: (_, _) =>
              const Scaffold(key: Key('hotspot-page'), body: SizedBox.shrink()),
        ),
        GoRoute(
          path: AppRoutes.bluetoothConnectPath,
          builder: (_, _) => const Scaffold(
            key: Key('bluetooth-page'),
            body: SizedBox.shrink(),
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
    // Bounded: the lobby's primary action carries a repeating pulse, so a
    // settle would wait on an animation that never ends.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a room with no link offers connecting instead of riding', (
    tester,
  ) async {
    final modeStore = _FakeModeStore(TransferMode.wifi);
    await pumpEntry(tester, links: LiveLinkSnapshot.none, modeStore: modeStore);

    expect(find.byKey(const Key('selected-room-link-callout')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-start-ride')), findsNothing);

    await tester.tap(find.byKey(const Key('selected-room-connect')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // The bridge, not a refusal and not the channel. A room whose local
    // member can hand out invites is the one the others are gathering
    // around, so it arrives on the hosting side.
    expect(find.byKey(const Key('hotspot-page')), findsOneWidget);
    // Nothing about the transport was decided by failing the gate.
    expect(modeStore.writes, isEmpty);
  });

  testWidgets('a stale transport still names the link the room will use', (
    tester,
  ) async {
    // Set to Bluetooth from a previous ride, standing on Wi-Fi today. The
    // channel would otherwise open on a repository with no link under it;
    // what the lobby reports is the link the gate would move it onto.
    final modeStore = _FakeModeStore(TransferMode.bluetooth);
    await pumpEntry(
      tester,
      links: const LiveLinkSnapshot(
        wifi: true,
        hostingHotspot: false,
        bluetooth: false,
      ),
      modeStore: modeStore,
    );

    expect(find.byKey(const Key('selected-room-link-chip')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
  });
}

class _FakeTransfer implements TransferRepository {
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
