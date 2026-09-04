import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';

/// What the lobby does about the link, which is the half of the gate the user
/// actually sees. The refusal itself lives in the composition root above; this
/// screen's job is to make sure the refusal is never the first the user hears
/// of it — a Start ride that silently does nothing is worse than no gate.
void main() {
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

  Future<void> pumpLobby(
    WidgetTester tester, {
    required LiveLink? link,
    VoidCallback? onConnect,
    VoidCallback? onStartRide,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: room(),
          link: link,
          onConnect: onConnect,
          onStartRide: onStartRide ?? () {},
          onBack: () {},
        ),
      ),
    );
    // Bounded rather than pumpAndSettle: the primary action carries a
    // repeating pulse, and a settle waits for an animation that never ends.
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('with no link, Start ride is replaced by the way to get one', (
    tester,
  ) async {
    var connects = 0;
    var starts = 0;
    await pumpLobby(
      tester,
      link: LiveLink.none,
      onConnect: () => connects++,
      onStartRide: () => starts++,
    );

    expect(find.byKey(const Key('selected-room-link-callout')), findsOneWidget);
    // The point of the whole change: the control that would open a channel
    // over nothing is not on the screen at all.
    expect(find.byKey(const Key('selected-room-start-ride')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('selected-room-connect')));
    await tester.tap(find.byKey(const Key('selected-room-connect')));
    expect(connects, 1);
    expect(starts, 0);
  });

  testWidgets('the roster survives losing the link', (tester) async {
    await pumpLobby(tester, link: LiveLink.none, onConnect: () {});

    // Who is in this room is durable and stays true whatever the radios are
    // doing; blanking it would make a temporary problem look like a lost room.
    expect(find.text('Rider one'), findsOneWidget);
    expect(find.text('Rider two'), findsOneWidget);
  });

  testWidgets('a caller with no way out keeps the original control', (
    tester,
  ) async {
    var starts = 0;
    await pumpLobby(
      tester,
      link: LiveLink.none,
      onStartRide: () => starts++,
    );

    expect(find.byKey(const Key('selected-room-link-callout')), findsOneWidget);
    expect(find.byKey(const Key('selected-room-connect')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    expect(starts, 1);
  });

  testWidgets('a link that is up is named, and Start ride is the point', (
    tester,
  ) async {
    var starts = 0;
    await pumpLobby(
      tester,
      link: LiveLink.wifi,
      onConnect: () {},
      onStartRide: () => starts++,
    );

    expect(find.byKey(const Key('selected-room-link-chip')), findsOneWidget);
    expect(find.text('On Wi-Fi'), findsOneWidget);
    expect(find.byKey(const Key('selected-room-link-callout')), findsNothing);

    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    expect(starts, 1);
  });

  testWidgets('being on a network is never reported as the room being ready', (
    tester,
  ) async {
    var connects = 0;
    await pumpLobby(
      tester,
      link: LiveLink.wifi,
      onConnect: () => connects++,
    );

    // The chip says what this phone is on. It must not say READY, because
    // "ready" is a claim about the room and nothing here can see the other
    // phones — which is exactly the lie the first build shipped.
    expect(find.text('On Wi-Fi'), findsOneWidget);
    expect(find.text('CONNECTED'), findsNothing);
    expect(
      find.textContaining('have to be on this same network'),
      findsOneWidget,
    );

    // And the gap has a way out, not just a warning.
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-different-network')),
    );
    await tester.tap(find.byKey(const Key('selected-room-different-network')));
    expect(connects, 1);
  });

  testWidgets('a Bluetooth link is proof of a peer, so it says so', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.bluetooth, onConnect: () {});

    // There is no such thing as being connected over Bluetooth to nobody, so
    // this is the one link that may confirm rather than merely report — and
    // the one with no "are we together?" way out to offer.
    expect(find.text('CONNECTED'), findsOneWidget);
    expect(
      find.byKey(const Key('selected-room-different-network')),
      findsNothing,
    );
  });

  testWidgets('a hotspot with nobody on it says that, not "ready"', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.hotspotHost, onConnect: () {});

    expect(
      find.textContaining('nobody is on it until they scan your code'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('selected-room-different-network')),
      findsOneWidget,
    );
  });

  testWidgets('hosting says so rather than claiming to be on a network', (
    tester,
  ) async {
    await pumpLobby(tester, link: LiveLink.hotspotHost, onConnect: () {});
    expect(find.text('Your hotspot is up'), findsOneWidget);
  });

  testWidgets('an unanswered probe changes nothing on the screen', (
    tester,
  ) async {
    var starts = 0;
    await pumpLobby(tester, link: null, onStartRide: () => starts++);

    // Null is "nobody has said yet", not "there is no link": a lobby that
    // flashed the callout for one frame on the way to Start ride would teach
    // the user to disbelieve the line.
    expect(find.byKey(const Key('selected-room-link-callout')), findsNothing);
    expect(find.byKey(const Key('selected-room-link-chip')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const Key('selected-room-start-ride')),
    );
    await tester.tap(find.byKey(const Key('selected-room-start-ride')));
    expect(starts, 1);
  });

  testWidgets('the Persian lobby says it in Persian at 320px', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpLobby(
      tester,
      link: LiveLink.none,
      onConnect: () {},
      locale: const Locale('fa'),
    );

    expect(find.text('هنوز وصل نیستید'), findsOneWidget);
    expect(find.text('برقراری اتصال'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
