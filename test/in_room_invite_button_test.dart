import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/core/motion/app_motion.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_lifecycle.dart';
import 'package:tark/feature/room/data/security/room_transport_identity_secure_store.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/in_room_invite_button.dart';
import 'package:tark/feature/transfer/api/hotspot_invite_api.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<SharedPreferencesRoomRepository> repositoryWithSelectedRoom() async {
    final repository = SharedPreferencesRoomRepository();
    final saved = await repository.create(
      name: 'Night ride',
      localDisplayName: 'Rider A',
    );
    await repository.select(saved.room.id);
    return repository;
  }

  Widget app({
    required SharedPreferencesRoomRepository repository,
    required Locale locale,
    HotspotLinkKeeper? hotspotLinkKeeper,
    TransferRepository? transferRepository,
  }) {
    return MediaQuery(
      data: const MediaQueryData(size: Size(320, 640)),
      child: MaterialApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('fa')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: InRoomInviteButton(
                repository: repository,
                identityLifecycle: RoomTransportIdentityLifecycle(
                  store: _MemoryIdentityStore(),
                ),
                hotspotLinkKeeper: hotspotLinkKeeper,
                transferRepository: transferRepository,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The invite QR carries a scanline that repeats for as long as it is on
  /// screen, so `pumpAndSettle` can never return once it is mounted. Every
  /// assertion past that point runs on bounded pumps instead.
  Future<void> settleInvite(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();
  }

  testWidgets('opening the roster issues nothing and adds nobody', (
    tester,
  ) async {
    // The regression this whole screen was rebuilt around: the old dialog
    // minted a durable member every time it was *opened*, so a host who
    // glanced at it three times ended up with three phantom riders and a
    // member count nobody else agreed with.
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();

    final before = (await repository.list()).single.room;
    expect(before.confirmedMembers, hasLength(1));

    for (var i = 0; i < 3; i++) {
      await openSheet(tester);
      expect(find.byKey(const Key('room-invite-qr')), findsNothing);
      Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
      await tester.pumpAndSettle();
    }

    final after = (await repository.list()).single.room;
    expect(after.confirmedMembers, hasLength(1));
    expect(after.pendingMembers, isEmpty);
    expect(after.members.where((m) => m.isActive), hasLength(1));
  });

  testWidgets('issuing an invite opens exactly one pending seat', (
    tester,
  ) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);

    expect(find.text('Night ride'), findsOneWidget);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);

    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-display-code')), findsOneWidget);

    final room = (await repository.list()).single.room;
    // The seat exists and is authorised, but nobody has walked through it —
    // so it must not inflate the head count.
    expect(room.pendingMembers, hasLength(1));
    expect(room.confirmedMembers, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a held seat can be taken back', (tester) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);
    expect((await repository.list()).single.room.pendingMembers, hasLength(1));

    // Close and reopen rather than tapping Done: the invite panel is taller
    // than the test surface, so Done sits below the fold. Reopening is also
    // the truer check — it proves the held seat is durable and shows up on the
    // roster of a freshly built sheet.
    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pumpAndSettle();
    await openSheet(tester);

    expect(find.text('OPEN SEATS (1)'), findsOneWidget);
    await tester.tap(find.byTooltip('Take the invite back'));
    await tester.pumpAndSettle();

    final room = (await repository.list()).single.room;
    expect(room.pendingMembers, isEmpty);
    expect(room.confirmedMembers, hasLength(1));
  });

  testWidgets('Persian entry and sheet preserve RTL at 320px', (tester) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('fa')),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection,
      TextDirection.rtl,
    );
    expect(find.byTooltip('فرد'), findsOneWidget);

    await openSheet(tester);
    expect(find.text('افراد اتاق'), findsOneWidget);

    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);

    expect(
      find.text('این کد فقط برای بررسی است و به‌تنهایی اجازه ورود نمی‌دهد.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('copying an invite answers on the button, not under the sheet', (
    tester,
  ) async {
    // The sheet is a modal, so it is drawn *over* the ScaffoldMessenger. The
    // SnackBar this used to raise landed underneath it and, from the user's
    // side, pressing Copy did nothing at all.
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);

    final copy = find.byKey(const Key('room-invite-copy'));
    await tester.ensureVisible(copy);
    await settleInvite(tester);
    expect(find.text('Copy invite'), findsOneWidget);

    await tester.tap(copy);
    await settleInvite(tester);

    expect(copied, hasLength(1));
    expect(copied.single, startsWith('tark-room:'));

    // The answer is on the control that was pressed.
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy invite'), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    // And nowhere else — a snack here would be invisible under the sheet.
    expect(find.byType(SnackBar), findsNothing);

    // It hands the action back rather than staying done forever.
    await tester.pump(AppMotion.confirmHold);
    await settleInvite(tester);
    expect(find.text('Copy invite'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no selected Room fails closed without issuing an invite', (
    tester,
  ) async {
    final repository = SharedPreferencesRoomRepository();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);

    expect(find.byKey(const Key('room-people-invite')), findsNothing);
    expect(find.text('No Room is selected.'), findsOneWidget);
  });

  testWidgets('only current transport host sees Wi-Fi credentials', (
    tester,
  ) async {
    final repository = await repositoryWithSelectedRoom();
    final keeper = _FakeHotspotLinkKeeper(
      state: HotspotLinkState.up,
      credentials: const HotspotCredentials(
        ssid: 'Tark-Ride',
        passphrase: 'host-secret',
      ),
    );

    await tester.pumpWidget(
      app(
        repository: repository,
        locale: const Locale('en'),
        hotspotLinkKeeper: keeper,
        transferRepository: _FakeTransferRepository(SessionRole.joiner),
      ),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);

    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);
    expect(find.textContaining('host-secret'), findsNothing);

    // Take the QR down before swapping the tree: its scanline repeats, so a
    // pumpAndSettle with one still mounted can never return.
    Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      app(
        repository: repository,
        locale: const Locale('en'),
        hotspotLinkKeeper: keeper,
        transferRepository: _FakeTransferRepository(SessionRole.host),
      ),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);

    expect(find.byKey(const Key('room-invite-wifi-section')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-wifi-qr')), findsOneWidget);
    expect(find.text('Network: Tark-Ride'), findsOneWidget);
    expect(find.text('Password: host-secret'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await keeper.dispose();
  });

  testWidgets('recovery disables stale Wi-Fi QR and refreshes credentials', (
    tester,
  ) async {
    final repository = await repositoryWithSelectedRoom();
    final keeper = _FakeHotspotLinkKeeper(
      state: HotspotLinkState.up,
      credentials: const HotspotCredentials(
        ssid: 'Old-SSID',
        passphrase: 'old-secret',
      ),
    );

    await tester.pumpWidget(
      app(
        repository: repository,
        locale: const Locale('en'),
        hotspotLinkKeeper: keeper,
        transferRepository: _FakeTransferRepository(SessionRole.host),
      ),
    );
    await tester.pumpAndSettle();
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('room-people-invite')));
    await settleInvite(tester);
    expect(find.text('Network: Old-SSID'), findsOneWidget);

    keeper.setState(HotspotLinkState.recovering);
    await settleInvite(tester);
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);
    expect(find.textContaining('old-secret'), findsNothing);
    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);

    keeper.setCredentials(
      const HotspotCredentials(ssid: 'New-SSID', passphrase: 'new-secret'),
    );
    await settleInvite(tester);
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);

    keeper.setState(HotspotLinkState.up);
    await settleInvite(tester);
    expect(find.byKey(const Key('room-invite-wifi-section')), findsOneWidget);
    expect(find.text('Network: New-SSID'), findsOneWidget);
    expect(find.text('Password: new-secret'), findsOneWidget);
    expect(find.textContaining('old-secret'), findsNothing);
    expect(tester.takeException(), isNull);
    await keeper.dispose();
  });
}

final class _MemoryIdentityStore implements RoomTransportIdentitySecureStore {
  final Map<String, RoomTransportIdentityMaterial> _values = {};

  String _key(RoomId roomId, RoomMemberId memberId) =>
      '${roomId.value}:${memberId.value}';

  @override
  Future<void> delete({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async {
    _values.remove(_key(roomId, memberId));
  }

  @override
  Future<RoomTransportIdentityMaterial?> read({
    required RoomId roomId,
    required RoomMemberId memberId,
  }) async => _values[_key(roomId, memberId)];

  @override
  Future<void> write({
    required RoomId roomId,
    required RoomMemberId memberId,
    required RoomTransportIdentityMaterial material,
  }) async {
    _values[_key(roomId, memberId)] = material;
  }
}

class _FakeTransferRepository implements TransferRepository {
  _FakeTransferRepository(this.role);

  final SessionRole role;

  @override
  SessionRole get sessionRole => role;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHotspotLinkKeeper implements HotspotLinkKeeper {
  _FakeHotspotLinkKeeper({
    required HotspotLinkState state,
    HotspotCredentials? credentials,
  }) : _state = state,
       _credentials = credentials;

  final _states = StreamController<HotspotLinkState>.broadcast(sync: true);
  final _credentialsChanges = StreamController<HotspotCredentials>.broadcast(
    sync: true,
  );
  HotspotLinkState _state;
  HotspotCredentials? _credentials;

  @override
  Stream<HotspotLinkState> get states => _states.stream;

  @override
  HotspotLinkState get state => _state;

  @override
  HotspotCredentials? get credentials => _credentials;

  @override
  Stream<HotspotCredentials> get credentialChanges =>
      _credentialsChanges.stream;

  void setState(HotspotLinkState value) {
    _state = value;
    _states.add(value);
  }

  void setCredentials(HotspotCredentials value) {
    _credentials = value;
    _credentialsChanges.add(value);
  }

  @override
  Future<void> release() async {}

  @override
  void retryNow() {}

  @override
  void adopt(HotspotCredentials credentials) => setCredentials(credentials);

  @override
  Future<void> dispose() async {
    await _states.close();
    await _credentialsChanges.close();
  }
}
