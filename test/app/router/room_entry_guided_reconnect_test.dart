import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/app/router/room_bound_walkie_entry.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/core/router/routes.dart';
import 'package:tark/core/settings/settings_keys.dart';
import 'package:tark/core/widget/qr_scanner_surface.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/hotspot_credentials.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_link_keeper.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// Start with no link between the phones opens a guided screen instead of
/// trying whatever network this phone is on: one phone shows a code, the
/// other scans it, and both pick the same side from the Room's history.
void main() {
  final getIt = GetIt.instance;
  const roomId = RoomId('0123456789abcdef0123456789abcdef');
  final localId = RoomMemberId('111111111111111111111111');
  final peerId = RoomMemberId('222222222222222222222222');

  tearDown(() async {
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

  Future<_FakeModeStore> pumpEntry(
    WidgetTester tester, {
    LiveLinkSnapshot links = LiveLinkSnapshot.none,
    RoomMemberId? lastHost,
    ValueNotifier<bool>? wifi,
    Future<HotspotCredentials?> Function()? prepareHost,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (lastHost != null)
        '${SettingsKeys.roomLastHotspotHostPrefix}${roomId.value}':
            lastHost.value,
    });
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
    final modeStore = _FakeModeStore(TransferMode.wifi);
    getIt.registerLazySingleton<RoomRepository>(
      () => _FakeRoomRepository(room()),
    );
    getIt.registerLazySingleton<LiveLinkProbe>(() => _FakeProbe(links));
    getIt.registerLazySingleton<TransferModeStore>(() => modeStore);
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
    getIt.registerLazySingleton<HotspotHost>(() => _FakeHotspotHost(wifi));
    getIt.registerLazySingleton<HotspotLinkKeeper>(_FakeKeeper.new);

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => const Scaffold()),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, _) => RoomBoundWalkieEntry(
            guidedReconnect: true,
            wifiCheck: wifi != null,
            prepareHost: prepareHost,
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
    return modeStore;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tapStart(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await settle(tester);
  }

  testWidgets('the Room creator shows the code the first time', (tester) async {
    await pumpEntry(tester);
    await tapStart(tester);

    expect(find.byKey(const ValueKey('room-reconnect-show')), findsOneWidget);
    expect(find.text('Connect with Rider two'), findsOneWidget);
    // No hotspot is available in this harness, so it says so in plain words
    // and offers both ways forward.
    expect(find.textContaining("couldn't start sharing"), findsOneWidget);
    expect(find.byKey(const Key('room-reconnect-retry')), findsOneWidget);
    expect(find.byKey(const Key('room-reconnect-switch')), findsOneWidget);
    // Nothing technical is asked of anybody.
    expect(find.textContaining('hotspot'), findsNothing);
    expect(find.textContaining('SSID'), findsNothing);
  });

  testWidgets('the switch turns this phone into the one that scans', (
    tester,
  ) async {
    await pumpEntry(tester);
    await tapStart(tester);
    await tester.tap(find.byKey(const Key('room-reconnect-switch')));
    await settle(tester);

    expect(find.byKey(const ValueKey('room-reconnect-scan')), findsOneWidget);
    expect(
      find.text("Point the camera at the code on Rider two's phone."),
      findsOneWidget,
    );
  });

  testWidgets('when the other phone hosted last time, this one scans', (
    tester,
  ) async {
    await pumpEntry(tester, lastHost: peerId);
    await tapStart(tester);

    expect(find.byKey(const ValueKey('room-reconnect-scan')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
  });

  testWidgets('a code that is not a connection code is named as such', (
    tester,
  ) async {
    await pumpEntry(tester, lastHost: peerId);
    await tapStart(tester);

    final surface = tester.widget<QrScannerSurface>(
      find.byType(QrScannerSurface),
    );
    expect(await surface.onCode('https://example.com'), isFalse);
    await tester.pump();

    expect(
      tester.widget<QrScannerSurface>(find.byType(QrScannerSurface)).errorText,
      "That isn't a Tarkk connection code. Scan the code on Rider two's phone.",
    );
  });

  testWidgets('a hotspot that never comes up gives up after a minute', (
    tester,
  ) async {
    final never = Completer<HotspotCredentials?>();
    await pumpEntry(tester, prepareHost: () => never.future);
    await tapStart(tester);

    expect(find.byKey(const ValueKey('room-reconnect-show')), findsOneWidget);
    expect(find.text('Getting your phone ready…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 58));
    expect(find.byKey(const Key('room-reconnect-retry')), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(find.textContaining("couldn't start sharing"), findsOneWidget);
    expect(find.byKey(const Key('room-reconnect-retry')), findsOneWidget);
    expect(find.byKey(const Key('room-reconnect-switch')), findsOneWidget);
  });

  group('Wi-Fi off', () {
    testWidgets('the scanning phone asks for Wi-Fi before the camera', (
      tester,
    ) async {
      final wifi = ValueNotifier(false);
      await pumpEntry(tester, lastHost: peerId, wifi: wifi);
      await tapStart(tester);

      expect(find.byKey(const ValueKey('room-reconnect-wifi')), findsOneWidget);
      expect(find.byType(QrScannerSurface), findsNothing);
      expect(find.text('Turn on Wi-Fi'), findsWidgets);
      expect(
        find.byKey(const Key('room-reconnect-turn-on-wifi')),
        findsOneWidget,
      );
      // The way out stays: this phone can still offer to show its own code.
      expect(find.byKey(const Key('room-reconnect-switch')), findsOneWidget);

      // Nothing to press once it is on: the camera takes over by itself.
      wifi.value = true;
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.byKey(const ValueKey('room-reconnect-wifi')), findsNothing);
      expect(find.byType(QrScannerSurface), findsOneWidget);
    });

    testWidgets('with Wi-Fi already on, the camera opens straight away', (
      tester,
    ) async {
      await pumpEntry(tester, lastHost: peerId, wifi: ValueNotifier(true));
      await tapStart(tester);

      expect(find.byKey(const ValueKey('room-reconnect-wifi')), findsNothing);
      expect(find.byType(QrScannerSurface), findsOneWidget);
    });

    testWidgets('the phone showing its code is never asked for Wi-Fi', (
      tester,
    ) async {
      await pumpEntry(tester, wifi: ValueNotifier(false));
      await tapStart(tester);

      expect(find.byKey(const ValueKey('room-reconnect-show')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-reconnect-wifi')), findsNothing);
    });

    testWidgets('back from the Wi-Fi card returns to the Room', (tester) async {
      await pumpEntry(tester, lastHost: peerId, wifi: ValueNotifier(false));
      await tapStart(tester);
      await tester.tap(find.byKey(const Key('room-reconnect-back')));
      await settle(tester);

      expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);
    });
  });

  testWidgets('back from the code returns to the Room, not out of it', (
    tester,
  ) async {
    await pumpEntry(tester);
    await tapStart(tester);
    await tester.tap(find.byKey(const Key('room-reconnect-back')));
    await settle(tester);

    expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);
    expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
  });

  testWidgets('home Wi-Fi is offered only while this phone is on Wi-Fi', (
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
    expect(
      find.byKey(const Key('selected-room-use-home-wifi')),
      findsOneWidget,
    );
  });

  testWidgets('and not at all without one', (tester) async {
    await pumpEntry(tester);
    expect(find.byKey(const Key('selected-room-use-home-wifi')), findsNothing);
  });

  testWidgets('home Wi-Fi, when asked for, skips the code entirely', (
    tester,
  ) async {
    final modeStore = await pumpEntry(
      tester,
      links: const LiveLinkSnapshot(
        wifi: true,
        hostingHotspot: false,
        bluetooth: false,
      ),
    );
    await tester.tap(find.byKey(const Key('selected-room-use-home-wifi')));
    await settle(tester);

    expect(find.byKey(const ValueKey('room-reconnect-show')), findsNothing);
    expect(find.byKey(const ValueKey('room-reconnect-scan')), findsNothing);
    expect(modeStore.writes, contains(TransferMode.wifi));
    // Let the existing-link attempt run out so no timer outlives the test.
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
  });
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

  /// This phone's Wi-Fi radio, when a test is about it.
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
