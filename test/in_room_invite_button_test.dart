import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tark/feature/room/data/repository/shared_preferences_room_repository.dart';
import 'package:tark/feature/room/presentation/widget/in_room_invite_button.dart';
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
                hotspotLinkKeeper: hotspotLinkKeeper,
                transferRepository: transferRepository,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('issues canonical Room invite and fits 320px', (tester) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-invite-dialog')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);
    expect(find.text('Night ride'), findsOneWidget);
    expect(find.byKey(const Key('room-invite-display-code')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Persian invite entry and sheet preserve RTL at 320px', (
    tester,
  ) async {
    final repository = await repositoryWithSelectedRoom();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('fa')),
    );

    expect(
      tester
          .widget<Directionality>(find.byType(Directionality).first)
          .textDirection,
      TextDirection.rtl,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('in-room-add-rider')))
          .tooltip,
      'افزودن همراه',
    );

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.text('دعوت به اتاق'), findsOneWidget);
    expect(
      find.text('این کد فقط برای بررسی است و به‌تنهایی اجازه ورود نمی‌دهد.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no selected Room fails closed without issuing an invite', (
    tester,
  ) async {
    final repository = SharedPreferencesRoomRepository();
    await tester.pumpWidget(
      app(repository: repository, locale: const Locale('en')),
    );

    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-invite-dialog')), findsNothing);
    expect(
      find.text('Select an active Room where you can manage invites first.'),
      findsOneWidget,
    );
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
    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);
    expect(find.textContaining('host-secret'), findsNothing);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      app(
        repository: repository,
        locale: const Locale('en'),
        hotspotLinkKeeper: keeper,
        transferRepository: _FakeTransferRepository(SessionRole.host),
      ),
    );
    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();

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
    await tester.tap(find.byKey(const Key('in-room-add-rider')));
    await tester.pumpAndSettle();
    expect(find.text('Network: Old-SSID'), findsOneWidget);

    keeper.setState(HotspotLinkState.recovering);
    await tester.pump();
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);
    expect(
      find.byKey(const Key('room-invite-wifi-recovering')),
      findsOneWidget,
    );
    expect(find.textContaining('old-secret'), findsNothing);
    expect(find.byKey(const Key('room-invite-qr')), findsOneWidget);

    keeper.setCredentials(
      const HotspotCredentials(ssid: 'New-SSID', passphrase: 'new-secret'),
    );
    await tester.pump();
    expect(find.byKey(const Key('room-invite-wifi-section')), findsNothing);

    keeper.setState(HotspotLinkState.up);
    await tester.pump();
    expect(find.byKey(const Key('room-invite-wifi-section')), findsOneWidget);
    expect(find.text('Network: New-SSID'), findsOneWidget);
    expect(find.text('Password: new-secret'), findsOneWidget);
    expect(find.textContaining('old-secret'), findsNothing);
    expect(tester.takeException(), isNull);
    await keeper.dispose();
  });
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
