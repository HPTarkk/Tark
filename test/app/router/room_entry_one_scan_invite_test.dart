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
import 'package:tark/core/widget/connection_journey.dart';
import 'package:tark/core/widget/journey_carry_over.dart';
import 'package:tark/core/widget/qr_widgets.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/domain/entity/room_direct_join_bundle.dart';
import 'package:tark/feature/room/domain/repository/room_repository.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';
import 'package:tark/feature/transfer/domain/entity/connection_health.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/session_role.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';
import 'package:tark/feature/transfer/domain/repository/transfer_repository.dart';
import 'package:tark/feature/transfer/domain/service/hotspot_control.dart';
import 'package:tark/feature/transfer/domain/service/live_link_probe.dart';
import 'package:tark/feature/transfer/domain/service/transfer_mode_store.dart';

/// The first invite of a freshly created Room (2026-10-05 field report: "it
/// took too long", then the scan led nowhere).
///
/// Nothing is hosting before a Room goes live, so the invite QR used to carry
/// membership alone: the person who scanned was in the Room with no network to
/// reach this phone, and this phone never learned anybody had scanned. One
/// scan has to be all it takes, so the inviting phone brings its link up first
/// and the code carries it.
void main() {
  final getIt = GetIt.instance;
  const creds = HotspotCredentials(
    ssid: 'AndroidShare_4410',
    passphrase: 'pass1234',
  );

  late SharedPreferencesRoomRepository rooms;
  late Map<String, Object?> identities;

  tearDown(() async {
    await getIt.reset();
  });

  Future<_FakeHost> pumpEntry(
    WidgetTester tester, {
    required Future<HotspotCredentials?> Function() prepareHost,
    bool withFriend = false,
    bool start = false,
    JourneyCarryOver? carryOver,
    bool settleFirstFrame = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    identities = {};
    const identityChannel = MethodChannel('tark/room_identity_secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      identityChannel,
      (call) async {
        final args = (call.arguments as Map).cast<String, Object?>();
        final key = '${args['roomId']}/${args['memberId']}';
        switch (call.method) {
          case 'write':
            identities[key] = args['material'];
            return null;
          case 'read':
            return identities[key];
          case 'delete':
            identities.remove(key);
            return null;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        identityChannel,
        null,
      ),
    );
    rooms = SharedPreferencesRoomRepository();
    final created = await tester.runAsync(
      () => rooms.create(name: 'Night ride', localDisplayName: 'Host'),
    );
    await tester.runAsync(() => rooms.select(created!.room.id));
    if (withFriend) {
      await tester.runAsync(
        () => rooms.admitVerifiedMember(
          created!.room.id,
          const RoomMemberId('ffffffffffffffffffffffff'),
          displayName: 'Sara',
          at: DateTime.utc(2026, 10, 12),
        ),
      );
    }

    final host = _FakeHost();
    getIt.registerLazySingleton<RoomRepository>(() => rooms);
    getIt.registerLazySingleton<LiveLinkProbe>(_FakeProbe.new);
    getIt.registerLazySingleton<TransferModeStore>(_FakeModeStore.new);
    getIt.registerLazySingleton<TransferRepository>(_FakeTransfer.new);
    getIt.registerLazySingleton<HotspotHost>(() => host);
    getIt.registerLazySingleton<HotspotLinkKeeper>(_IdleKeeper.new);

    final router = GoRouter(
      initialLocation: AppRoutes.walkiePath,
      routes: [
        GoRoute(path: AppRoutes.roomsPath, builder: (_, _) => const Scaffold()),
        GoRoute(
          path: AppRoutes.walkiePath,
          builder: (_, _) => RoomBoundWalkieEntry(
            guidedReconnect: true,
            wifiCheck: true,
            prepareHost: prepareHost,
            start: start,
            carryOver: carryOver,
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
    if (!settleFirstFrame) return host;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return host;
  }

  /// Lets the invite sheet issue its code: storage and crypto are real here,
  /// so they need real time, not only frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapInvite(WidgetTester tester) async {
    final invite = find.byKey(const Key('selected-room-invite-callout'));
    await tester.ensureVisible(invite);
    await tester.pump();
    await tester.tap(invite);
    await settle(tester);
  }

  /// Unmounts the entry and runs out every timer it left behind.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 4));
  }

  testWidgets(
    'the first invite of a new Room carries this phone\'s hotspot as well',
    (tester) async {
      var prepared = 0;
      await pumpEntry(
        tester,
        prepareHost: () async {
          prepared++;
          return creds;
        },
      );
      expect(find.byKey(const Key('selected-room-lobby')), findsOneWidget);

      await tapInvite(tester);

      expect(prepared, 1, reason: 'the link comes up before the code shows');
      final qr = tester.widget<GlowingQrCard>(
        find.byKey(const Key('one-scan-room-invite-qr')),
      );
      final scanned = ScannedCode.parse(qr.data);
      expect(scanned, isNotNull, reason: 'one standard Wi-Fi code');
      expect(scanned!.credentials, creds);
      // …that also carries the Room, so the same scan joins both.
      final bundle = RoomDirectJoinBundle.decode(scanned.roomInvite!);
      // The seat the code opens is on this phone's roster, so the newcomer's
      // proof is for somebody this phone is already waiting on.
      final saved = await tester.runAsync(
        () async => rooms.get((await rooms.selectedRoomId())!),
      );
      expect(
        saved!.room.activeMembers.map((m) => m.id),
        contains(bundle.memberId),
      );
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'Connect works straight after closing the invite, without waiting out '
    'the invite\'s grace',
    (tester) async {
      // 2026-10-12: invite, close the code, tap Connect — nothing, until the
      // person left the Room or locked the screen. The closed sheet's wait
      // was still the attempt in progress and swallowed every tap.
      await pumpEntry(tester, prepareHost: () async => creds, withFriend: true);
      await tapInvite(tester);
      expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);

      // Close the sheet.
      final done = find.byKey(const Key('one-scan-room-invite-done'));
      await tester.ensureVisible(done);
      await tester.tap(done);
      await settle(tester);
      expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);

      final connect = find.byKey(const Key('selected-room-start-ride'));
      expect(connect, findsOneWidget);
      await tester.tap(connect);
      await settle(tester);
      // The existing link gets its short try, then the guided step opens —
      // well inside the 45 s the closed invite used to hold on for.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        if (find
            .byKey(const ValueKey('room-reconnect'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(const ValueKey('room-reconnect')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets(
    'a scan\'s journey carries on from the entry\'s very first frame',
    (tester) async {
      // 2026-10-12: the joiner watched the link being made, then a blank
      // page, then the same scene again — the entry had nothing to draw until
      // it had read the Room back from storage.
      await pumpEntry(
        tester,
        prepareHost: () async => creds,
        start: true,
        carryOver: const JourneyCarryOver(
          link: JourneyLink.hotspot,
          caption: 'Night ride',
        ),
        settleFirstFrame: false,
      );
      expect(find.byKey(const ValueKey('room-entry-journey')), findsOneWidget);
      expect(find.byKey(const ValueKey('walkie-entry-waiting')), findsNothing);
      expect(find.text('Night ride'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('a hotspot that cannot start shows no code that cannot connect', (
    tester,
  ) async {
    await pumpEntry(tester, prepareHost: () async => null);

    await tapInvite(tester);

    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);
    expect(
      find.byKey(const Key('one-scan-room-invite-unavailable')),
      findsOneWidget,
    );
    expect(find.textContaining("couldn't start sharing"), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('while the hotspot comes up the sheet says it is getting ready', (
    tester,
  ) async {
    final hosting = Completer<HotspotCredentials?>();
    await pumpEntry(tester, prepareHost: () => hosting.future);

    await tapInvite(tester);

    expect(
      find.byKey(const Key('one-scan-room-invite-preparing')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsNothing);

    hosting.complete(creds);
    await settle(tester);
    expect(find.byKey(const Key('one-scan-room-invite-qr')), findsOneWidget);
    await finish(tester);
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

class _FakeHost implements HotspotHost {
  int stops = 0;

  @override
  bool get isHosting => false;

  /// Wi-Fi already off: no "turn off Wi-Fi" page in the way.
  @override
  Future<HotspotWifiAdvice> wifiAdvice() async => const HotspotWifiAdvice(
    wifiEnabled: false,
    concurrent: true,
    canPanel: true,
  );

  @override
  Future<void> stop() async => stops++;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _IdleKeeper implements HotspotLinkKeeper {
  @override
  HotspotLinkState get state => HotspotLinkState.idle;

  @override
  HotspotCredentials? get credentials => null;

  @override
  Stream<HotspotLinkState> get states => const Stream.empty();

  @override
  Stream<HotspotCredentials> get credentialChanges => const Stream.empty();

  @override
  Future<void> release() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeProbe implements LiveLinkProbe {
  /// This phone is hosting: the hotspot raised for the invite.
  @override
  Future<LiveLinkSnapshot> read() async => const LiveLinkSnapshot(
    wifi: false,
    hostingHotspot: true,
    bluetooth: false,
  );

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

class _FakeModeStore implements TransferModeStore {
  TransferMode _mode = TransferMode.wifi;

  @override
  TransferMode get mode => _mode;

  @override
  TransferMode? get pinnedMode => null;

  @override
  Future<void> setMode(TransferMode mode) async => _mode = mode;

  @override
  Stream<TransferMode> get modeChanges => const Stream<TransferMode>.empty();

  @override
  Stream<TransferMode?> get pinChanges => const Stream<TransferMode?>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setPinnedMode(TransferMode? mode) async {}
}
