import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tark/core/l10n/app_localizations.dart';
import 'package:tark/feature/room/domain/entity/room.dart';
import 'package:tark/feature/room/presentation/widget/selected_room_lobby.dart';
import 'package:tark/feature/transfer/domain/entity/live_link.dart';
import 'package:tark/feature/transfer/domain/entity/transfer_mode.dart';

/// What the lobby does about the link, which is the half of the gate the user
/// actually sees. The refusal itself lives in the composition root above; this
/// screen's job is to make sure the refusal is never the first the user hears
/// of it — a Start ride that silently does nothing is worse than no gate.
void main() {
  SavedRoom room({bool alone = false}) {
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
          if (!alone)
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
    TransferMode? mode,
    VoidCallback? onConnect,
    VoidCallback? onStartRide,
    Locale locale = const Locale('en'),
    bool alone = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SelectedRoomLobby(
          room: room(alone: alone),
          link: link,
          mode: mode,
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
    await pumpLobby(tester, link: LiveLink.none, onStartRide: () => starts++);

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
      // A joiner that came through the bridge: the same Wi-Fi association a
      // router would give, and the transport is what remembers it was agreed.
      mode: TransferMode.hotspot,
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
      mode: TransferMode.hotspot,
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
    await pumpLobby(
      tester,
      link: LiveLink.hotspotHost,
      mode: TransferMode.hotspot,
      onConnect: () {},
    );

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

  group('a network nobody arranged is not the way through', () {
    testWidgets('the bridge leads and Start ride steps down to a line', (
      tester,
    ) async {
      var connects = 0;
      var starts = 0;
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        // The home network, found rather than agreed — the case the whole
        // inversion exists for.
        mode: TransferMode.wifi,
        onConnect: () => connects++,
        onStartRide: () => starts++,
      );

      // The two swap places. What used to be the glowing amber control is
      // gone, and what used to be one line of small underlined text is now
      // the thing the screen argues for.
      expect(
        find.byKey(const Key('selected-room-shared-network-callout')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('selected-room-start-ride')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const Key('selected-room-connect')),
      );
      await tester.tap(find.byKey(const Key('selected-room-connect')));
      expect(connects, 1);
      expect(starts, 0);
    });

    testWidgets('and "we are already together" is still one tap', (
      tester,
    ) async {
      var starts = 0;
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.wifi,
        onConnect: () {},
        onStartRide: () => starts++,
      );

      // A pair genuinely sat on one office network gets on the air in exactly
      // the tap it always took. The inversion changed which of the two the
      // screen argues for, not whether the other one is reachable.
      await tester.ensureVisible(
        find.byKey(const Key('selected-room-start-anyway')),
      );
      await tester.tap(find.byKey(const Key('selected-room-start-anyway')));
      expect(starts, 1);
    });

    testWidgets('the warning is not also shown small above the callout', (
      tester,
    ) async {
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.wifi,
        onConnect: () {},
      );

      // The chip stays — what this phone is on is worth saying — but one
      // warning in two sizes would read as two different problems.
      expect(find.byKey(const Key('selected-room-link-chip')), findsOneWidget);
      expect(
        find.byKey(const Key('selected-room-different-network')),
        findsNothing,
      );
      expect(
        find.textContaining('have to be on this same network'),
        findsNothing,
      );
    });

    testWidgets('a bridge that put this phone here is never demoted', (
      tester,
    ) async {
      var starts = 0;
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.hotspot,
        onConnect: () {},
        onStartRide: () => starts++,
      );

      // Same radio state as the test above, opposite verdict, and the mode is
      // the only thing that tells them apart. Telling a joiner who just
      // scanned the host's code to go and get on one network would send them
      // back through the screen they came from.
      expect(
        find.byKey(const Key('selected-room-shared-network-callout')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const Key('selected-room-start-ride')),
      );
      await tester.tap(find.byKey(const Key('selected-room-start-ride')));
      expect(starts, 1);
    });

    testWidgets('with no way out to offer, the original control comes back', (
      tester,
    ) async {
      var starts = 0;
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.wifi,
        onStartRide: () => starts++,
      );

      // There is nothing to invert towards, and a screen whose only action is
      // a sentence is worse than the shape this replaced.
      expect(
        find.byKey(const Key('selected-room-shared-network-callout')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('selected-room-connect')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('selected-room-start-ride')),
      );
      await tester.tap(find.byKey(const Key('selected-room-start-ride')));
      expect(starts, 1);
    });

    testWidgets('the first invite outranks borrowed-network doubt', (
      tester,
    ) async {
      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.wifi,
        onConnect: () {},
        alone: true,
      );

      // A one-person Room has nobody to reach yet. Its first Tark invite now
      // bootstraps an app-owned hotspot before minting the single QR, so a
      // borrowed/home Wi-Fi association must not send the creator back through
      // transport setup before they have even invited the first rider.
      expect(
        find.byKey(const Key('selected-room-shared-network-callout')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('selected-room-invite-callout')),
        findsOneWidget,
      );
    });

    testWidgets('the Persian inversion reads in Persian at 320px', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await pumpLobby(
        tester,
        link: LiveLink.wifi,
        mode: TransferMode.wifi,
        onConnect: () {},
        locale: const Locale('fa'),
      );

      expect(find.text('همه روی همین شبکه‌اند؟'), findsOneWidget);
      expect(find.text('یک شبکهٔ مشترک بسازید'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
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
