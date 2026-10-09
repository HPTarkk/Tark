import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:tark/core/entitlement/license_gate.dart';
import 'package:tark/core/entitlement/premium_feature.dart';
import 'package:tark/core/entitlement/billing_service.dart';
import 'package:tark/core/entitlement/plan_catalog.dart';
import 'package:tark/core/entitlement/subscription_service.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

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

  Future<_FakeModeStore> pumpEntry(
    WidgetTester tester, {
    required LiveLinkSnapshot links,
    TransferMode mode = TransferMode.wifi,
    TransferMode? pinned,
    LicenseGate? gate,
  }) async {
    if (gate != null) getIt.registerSingleton<LicenseGate>(gate);
    final modeStore = _FakeModeStore(mode, pinned: pinned);
    getIt.registerLazySingleton<RoomRepository>(
      () => _FakeRoomRepository(room()),
    );
    getIt.registerLazySingleton<LiveLinkProbe>(() => _FakeProbe(links));
    getIt.registerLazySingleton<TransferModeStore>(() => modeStore);
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
    getIt.registerLazySingleton<HotspotHost>(_FakeHotspotHost.new);
    getIt.registerLazySingleton<HotspotLinkKeeper>(_FakeKeeper.new);

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => const Scaffold()),
        GoRoute(
          path: AppRoutes.bluetoothConnectPath,
          builder: (_, state) => Scaffold(
            body: Text('Bluetooth ${state.uri.queryParameters['intent']}'),
          ),
        ),
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
    return modeStore;
  }

  void expectTransportInvisible() {
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-link-callout')), findsNothing);
    expect(find.byKey(const Key('selected-room-link-chip')), findsNothing);
    expect(find.byKey(const Key('selected-room-connect')), findsNothing);
    expect(
      find.byKey(const Key('selected-room-different-network')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('selected-room-shared-network-callout')),
      findsNothing,
    );
  }

  testWidgets('no-link entry remains Room-first rather than setup-first', (
    tester,
  ) async {
    final modeStore = await pumpEntry(tester, links: LiveLinkSnapshot.none);

    expectTransportInvisible();

    // This harness intentionally has no hidden bootstrap bridge registered.
    // Pressing Start therefore exercises the router's safety backstop and
    // returns to the same Room rather than exposing a technical setup page.
    expect(find.text('Connect phones'), findsOneWidget);
    // Missing links are identified before the first connection attempt.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);
    expectTransportInvisible();
    expect(modeStore.writes, isEmpty);

    // With no hand-off to plan and no link to try, the failure says what is
    // wrong in plain words and offers the one thing that fixes it, rather
    // than a retry that can only fail the same way.
    expect(
      find.text("These phones aren't linked right now. Connect them to start."),
      findsOneWidget,
    );
    expect(find.byKey(const Key('selected-room-connect-phones')), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
  });

  testWidgets('local Wi-Fi never turns into a same-network instruction', (
    tester,
  ) async {
    await pumpEntry(
      tester,
      links: const LiveLinkSnapshot(
        wifi: true,
        hostingHotspot: false,
        bluetooth: false,
      ),
    );

    expectTransportInvisible();
    expect(find.textContaining('same network'), findsNothing);
  });

  testWidgets('stale transport mode is not surfaced in the Room lobby', (
    tester,
  ) async {
    await pumpEntry(
      tester,
      links: const LiveLinkSnapshot(
        wifi: true,
        hostingHotspot: false,
        bluetooth: false,
      ),
      mode: TransferMode.bluetooth,
    );

    expectTransportInvisible();
    expect(find.text('On Wi-Fi'), findsNothing);
    expect(find.text('CONNECTED'), findsNothing);
  });

  testWidgets(
    'a legacy automatic preference does not silently use an available Bluetooth link',
    (tester) async {
      final store = await pumpEntry(
        tester,
        links: const LiveLinkSnapshot(
          wifi: false,
          hostingHotspot: false,
          bluetooth: true,
        ),
        mode: TransferMode.bluetooth,
        gate: _LockedGate(),
      );
      expect(find.text('Unlock Premium'), findsOneWidget);
      expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
      expect(
        find.byKey(const Key('selected-room-free-bluetooth')),
        findsOneWidget,
      );
      expect(store.writes, isEmpty);
    },
  );

  testWidgets(
    'free alternative pins Bluetooth and opens pairing without a subscription',
    (tester) async {
      final store = await pumpEntry(
        tester,
        links: LiveLinkSnapshot.none,
        gate: _LockedGate(),
      );
      await tester.tap(find.byKey(const Key('selected-room-free-bluetooth')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.pinnedMode, TransferMode.bluetooth);
      expect(store.mode, TransferMode.bluetooth);
      expect(find.text('Bluetooth create'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'asking for Premium leaves the lobby idle until access is granted',
    (tester) async {
      final subscription = _PendingSubscription();
      getIt.registerSingleton<SubscriptionService>(subscription);
      getIt.registerSingleton<BillingService>(
        const UnavailableBillingService(),
      );
      getIt.registerSingleton<PlanCatalog>(_EmptyPlans());
      await pumpEntry(
        tester,
        links: LiveLinkSnapshot.none,
        gate: _LockedGate(),
      );
      await tester.tap(find.byKey(const Key('selected-room-start-ride')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('paywall-free-bluetooth')), findsOneWidget);
      expect(
        find.text('Connect with Premium', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Connecting', skipOffstage: false), findsNothing);
      Navigator.of(
        tester.element(find.byKey(const Key('paywall-free-bluetooth'))),
      ).pop(false);
      subscription.answer.complete(const GateSignInRequired());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Unlock Premium'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a Bluetooth pin is never traded for the Wi-Fi that is up', (
    tester,
  ) async {
    // The field report: pinned to Bluetooth, still on home Wi-Fi, and Start
    // "connected" the Room over that Wi-Fi. With Wi-Fi then switched off the
    // Room was on nothing the user had chosen.
    final modeStore = await pumpEntry(
      tester,
      links: const LiveLinkSnapshot(
        wifi: true,
        hostingHotspot: false,
        bluetooth: false,
      ),
      mode: TransferMode.bluetooth,
      pinned: TransferMode.bluetooth,
    );

    expect(find.text('Connect phones'), findsOneWidget);

    // Start sits below Invite and can be under the fold.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(modeStore.writes, [TransferMode.bluetooth]);
    expect(modeStore.mode, TransferMode.bluetooth);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Bluetooth create'), findsOneWidget);
  });
}

class _FakeTransfer implements TransferRepository {
  @override
  SessionRole get sessionRole => SessionRole.unknown;

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
  _FakeModeStore(this._mode, {this.pinned});

  TransferMode _mode;
  TransferMode? pinned;
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
  Future<void> setPinnedMode(TransferMode? mode) async {
    pinned = mode;
    if (mode != null) await setMode(mode);
  }
}

class _LockedGate implements LicenseGate {
  @override
  bool allows(PremiumFeature feature) => false;
  @override
  bool get canPurchase => true;
  @override
  Stream<void> get changes => const Stream.empty();
}

class _PendingSubscription implements SubscriptionService {
  final answer = Completer<GateOutcome>();
  @override
  Future<GateOutcome> check() => answer.future;
  @override
  bool get isPremiumActive => false;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _EmptyPlans implements PlanCatalog {
  @override
  Future<List<BillingPlan>> load() async => const [];
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
