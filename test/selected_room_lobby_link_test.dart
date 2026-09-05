import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';
import 'package:tark/feature/transfer/api/transfer_api.dart';

void main() {
  SavedRoom room({bool localIsPreferred = true}) {
    final firstId = RoomMemberId('111111111111111111111111');
    final secondId = RoomMemberId('222222222222222222222222');
    final now = DateTime.utc(2026, 9, 5, 7);
    return SavedRoom(
      room: Room(
        id: const RoomId('0123456789abcdef0123456789abcdef'),
        name: 'Night ride',
        createdAt: now,
        updatedAt: now,
        members: [
          RoomMember(id: firstId, displayName: 'Rider one', joinedAt: now),
          RoomMember(
            id: secondId,
            displayName: 'Rider two',
            joinedAt: now.add(const Duration(seconds: 1)),
          ),
        ],
      ),
      membership: RoomMembership(
        localMemberId: localIsPreferred ? firstId : secondId,
        canManageInvites: true,
      ),
    );
  }

  Future<void> pumpLobby(
    WidgetTester tester, {
    required LiveLink? link,
    TransferMode? mode,
    SavedRoom? savedRoom,
    PreLiveHotspotBootstrap? bootstrap,
    VoidCallback? onStartRide,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: savedRoom ?? room(),
          link: link,
          mode: mode,
          preLiveBootstrap: bootstrap,
          onStartRide: onStartRide ?? () {},
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('normal lobby never exposes transport setup mechanics', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.none, mode: TransferMode.wifi);

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
  });

  testWidgets('existing Wi-Fi is tried without raising a new hotspot', (
    tester,
  ) async {
    var bootstraps = 0;
    var starts = 0;
    final bootstrap = PreLiveHotspotBootstrap(
      starter: () async {
        bootstraps++;
        return null;
      },
    );

    await pumpLobby(
      tester,
      link: LiveLink.wifi,
      mode: TransferMode.wifi,
      bootstrap: bootstrap,
      onStartRide: () => starts++,
    );

    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();

    expect(bootstraps, 0);
    expect(starts, 1);
  });

  testWidgets('preferred host hides hotspot bootstrap behind Start', (
    tester,
  ) async {
    var bootstraps = 0;
    var starts = 0;
    final bootstrap = PreLiveHotspotBootstrap(
      starter: () async {
        bootstraps++;
        return null;
      },
    );

    await pumpLobby(
      tester,
      link: LiveLink.none,
      mode: TransferMode.wifi,
      bootstrap: bootstrap,
      onStartRide: () => starts++,
    );

    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();
    await tester.pump();

    expect(bootstraps, 1);
    expect(starts, 1);
    expect(find.byKey(const Key('selected-room-connect')), findsNothing);
  });

  testWidgets('non-preferred member never self-promotes in the lobby', (
    tester,
  ) async {
    var bootstraps = 0;
    var starts = 0;
    final bootstrap = PreLiveHotspotBootstrap(
      starter: () async {
        bootstraps++;
        return null;
      },
    );

    await pumpLobby(
      tester,
      link: LiveLink.none,
      mode: TransferMode.wifi,
      savedRoom: room(localIsPreferred: false),
      bootstrap: bootstrap,
      onStartRide: () => starts++,
    );

    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    await tester.pump();

    expect(bootstraps, 0);
    expect(starts, 1);
  });

  testWidgets('transport state never changes the durable roster', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.none);
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);

    await pumpLobby(
      tester,
      link: LiveLink.bluetooth,
      mode: TransferMode.bluetooth,
    );
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
  });

  testWidgets('Persian lobby also contains no connection instructions', (
    tester,
  ) async {
    await pumpLobby(
      tester,
      link: LiveLink.none,
      mode: TransferMode.wifi,
      locale: const Locale('fa'),
    );

    expect(find.text('برقراری اتصال'), findsNothing);
    expect(find.text('هنوز وصل نیستید'), findsNothing);
    expect(find.byKey(const Key('selected-room-start-ride')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
